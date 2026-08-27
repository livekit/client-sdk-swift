/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Combine
import Foundation

internal import LiveKitWebRTC

@objcMembers
public class E2EEManager: NSObject, @unchecked Sendable, ObservableObject, Loggable {
    // Private delegate adapter to hide RTCFrameCryptorDelegate symbol
    private class DelegateAdapter: NSObject, LKRTCFrameCryptorDelegate {
        weak var target: E2EEManager?

        init(target: E2EEManager? = nil) {
            self.target = target
        }

        func frameCryptor(_ frameCryptor: LKRTCFrameCryptor,
                          didStateChangeWithParticipantId participantId: String,
                          with stateChanged: LKRTCFrameCryptorState)
        {
            // Redirect
            target?.frameCryptor(frameCryptor, didStateChangeWithParticipantId: participantId, with: stateChanged)
        }
    }

    // MARK: - Public

    public let e2eeOptions: E2EEOptions?
    public let options: EncryptionOptions?

    public var keyProvider: BaseKeyProvider {
        options?.keyProvider ?? e2eeOptions?.keyProvider ?? BaseKeyProvider()
    }

    public var frameEncryptionType: EncryptionType {
        options?.encryptionType ?? e2eeOptions?.encryptionType ?? .none
    }

    public var isDataChannelEncryptionEnabled: Bool {
        _state.enabled && options != nil
    }

    /// Whether data-track frames should be encrypted: the runtime flag plus a configured
    /// encryption type, honoring either options style (unlike the data-channel gate, which
    /// requires the newer ``EncryptionOptions``).
    var isDataTrackEncryptionEnabled: Bool {
        _state.enabled && frameEncryptionType != .none
    }

    public var dataChannelEncryptionType: EncryptionType {
        guard isDataChannelEncryptionEnabled else { return .none }
        return options?.encryptionType ?? .none
    }

    // MARK: - Private

    // Reference to Room
    private weak var _room: Room?

    private lazy var delegateAdapter: DelegateAdapter = .init(target: self)

    private var _state = StateSync(State())

    private struct State: Equatable {
        var enabled: Bool = true
        var frameCryptors = [[Participant.Identity: Track.Sid]: LKRTCFrameCryptor]()
        var trackPublications = [LKRTCFrameCryptor: TrackPublication]()
        var dataCryptor: LKRTCDataPacketCryptor?
        /// Publications whose detach ran before the deferred attach landed: the sid is tombstoned so
        /// the late attach skips installing a cryptor for a track that no longer exists.
        var staleSids: Set<Track.Sid> = []
    }

    public init(e2eeOptions: E2EEOptions) {
        self.e2eeOptions = e2eeOptions
        options = nil
    }

    public init(options: EncryptionOptions) {
        e2eeOptions = nil
        self.options = options
    }

    public func setup(room: Room) {
        if _room != room { cleanUp() }
        _room = room

        room.add(delegate: self)

        let localPublications = room.localParticipant.trackPublications.values.compactMap { $0 as? LocalTrackPublication }

        for publication in localPublications {
            if let participantIdentity = room.localParticipant.identity {
                Task { await addRtpSender(publication: publication, participantIdentity: participantIdentity) }
            }
        }

        for remoteParticipant in room.remoteParticipants.values {
            let remotePublications = remoteParticipant.trackPublications.values.compactMap { $0 as? RemoteTrackPublication }

            for publication in remotePublications {
                if let participantIdentity = remoteParticipant.identity {
                    Task { await addRtpReceiver(publication: publication, participantIdentity: participantIdentity) }
                }
            }
        }

        addDataChannelCryptor()
    }

    public func enableE2EE(enabled: Bool) {
        _state.mutate {
            $0.enabled = enabled
            for (_, frameCryptor) in $0.frameCryptors {
                frameCryptor.enabled = enabled
            }
        }
    }

    func addRtpSender(publication: LocalTrackPublication, participantIdentity: Participant.Identity) async {
        guard publication.encryptionType != .none else {
            log("encryptionType is .none, skipping creating frame cryptor...", .warning)
            return
        }

        guard let sender = publication.track?._state.rtpSender else {
            log("sender is nil, skipping creating frame cryptor...", .warning)
            return
        }

        // The raw sender is `@RTC`-confined and `LKRTCFrameCryptor` is not `Sendable`, so build
        // and install it entirely on the RTC executor.
        let installed: Bool = await RTC.run {
            guard let frameCryptor = LKRTCFrameCryptor(factory: RTC.peerConnectionFactory,
                                                       rtpSender: sender.raw,
                                                       participantId: participantIdentity.stringValue,
                                                       algorithm: .aesGcm,
                                                       keyProvider: keyProvider.rtcKeyProvider)
            else {
                log("frameCryptor is nil, skipping creating frame cryptor...", .warning)
                return false
            }

            frameCryptor.delegate = delegateAdapter
            return _state.mutate {
                guard $0.staleSids.remove(publication.sid) == nil else { return false }
                $0.frameCryptors[[participantIdentity: publication.sid]] = frameCryptor
                $0.trackPublications[frameCryptor] = publication
                frameCryptor.enabled = $0.enabled
                return true
            }
        }
        if !installed { log("Track was unpublished before its frame cryptor attached; skipping", .warning) }
    }

    func addRtpReceiver(publication: RemoteTrackPublication, participantIdentity: Participant.Identity) async {
        guard publication.encryptionType != .none else {
            log("encryptionType is .none, skipping creating frame cryptor...", .warning)
            return
        }

        guard let receiver = publication.track?._state.rtpReceiver else {
            log("receiver is nil, skipping creating frame cryptor...", .warning)
            return
        }

        // The raw receiver is `@RTC`-confined and `LKRTCFrameCryptor` is not `Sendable`, so build
        // and install it entirely on the RTC executor.
        let installed: Bool = await RTC.run {
            guard let frameCryptor = LKRTCFrameCryptor(factory: RTC.peerConnectionFactory,
                                                       rtpReceiver: receiver.raw,
                                                       participantId: participantIdentity.stringValue,
                                                       algorithm: .aesGcm,
                                                       keyProvider: keyProvider.rtcKeyProvider)
            else {
                log("frameCryptor is nil, skipping creating frame cryptor...", .warning)
                return false
            }

            frameCryptor.delegate = delegateAdapter
            return _state.mutate {
                guard $0.staleSids.remove(publication.sid) == nil else { return false }
                $0.frameCryptors[[participantIdentity: publication.sid]] = frameCryptor
                $0.trackPublications[frameCryptor] = publication
                frameCryptor.enabled = $0.enabled
                return true
            }
        }
        if !installed { log("Track was unsubscribed before its frame cryptor attached; skipping", .warning) }
    }

    func addDataChannelCryptor() {
        _state.mutate {
            $0.dataCryptor = LKRTCDataPacketCryptor(algorithm: .aesGcm, keyProvider: keyProvider.rtcKeyProvider)
        }
    }

    public func cleanUp() {
        cleanUp(isFullReconnect: false)
    }

    func cleanUp(isFullReconnect: Bool) {
        _state.mutate {
            for (_, frameCryptor) in $0.frameCryptors {
                frameCryptor.delegate = nil
            }
            $0.frameCryptors.removeAll()
            $0.trackPublications.removeAll()
            $0.staleSids.removeAll()
            // The data cryptor is key-provider-scoped (not bound to a transport), and its users —
            // encrypted data payloads and the data-track subsystem — survive a full reconnect, so
            // keep it: nothing re-runs setup() until the next explicit connect.
            if !isFullReconnect {
                $0.dataCryptor = nil
            }
        }
    }
}

// MARK: - Frame encryption

extension E2EEManager {
    func frameCryptor(_ frameCryptor: LKRTCFrameCryptor, didStateChangeWithParticipantId participantId: String, with state: LKRTCFrameCryptorState) {
        guard let room = _room else {
            log("room is nil", .warning)
            return
        }

        guard let publication = _state.read({ $0.trackPublications[frameCryptor] }) else {
            log("publication is nil", .warning)
            return
        }

        log("frameCryptor didStateChangeWithParticipantId \(participantId) with state \(state.rawValue)")

        room.delegates.notify { delegate in
            delegate.room?(room, trackPublication: publication, didUpdateE2EEState: state.toLKType())
        }
    }
}

extension E2EEManager: RoomDelegate {
    public func room(_: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        if let participantIdentity = participant.identity {
            Task { await addRtpSender(publication: publication, participantIdentity: participantIdentity) }
        }
    }

    public func room(_: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        _state.mutate {
            if let participantIdentity = participant.identity {
                if let frameCryptor = ($0.frameCryptors.first { (key: [Participant.Identity: Track.Sid], _: LKRTCFrameCryptor) in
                    key[participantIdentity] == publication.sid
                })?.value {
                    frameCryptor.delegate = nil
                    frameCryptor.enabled = false

                    $0.trackPublications.removeValue(forKey: frameCryptor)
                    $0.frameCryptors.removeValue(forKey: [participantIdentity: publication.sid])
                } else {
                    // The deferred attach has not landed yet; tombstone the sid so it skips.
                    $0.staleSids.insert(publication.sid)
                }
            }
        }
    }

    public func room(_: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        if let participantIdentity = participant.identity {
            Task { await addRtpReceiver(publication: publication, participantIdentity: participantIdentity) }
        }
    }

    public func room(_: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        _state.mutate {
            if let participantIdentity = participant.identity {
                if let frameCryptor = ($0.frameCryptors.first { (key: [Participant.Identity: Track.Sid], _: LKRTCFrameCryptor) in
                    key[participantIdentity] == publication.sid
                })?.value {
                    frameCryptor.delegate = nil
                    frameCryptor.enabled = false

                    $0.trackPublications.removeValue(forKey: frameCryptor)
                    $0.frameCryptors.removeValue(forKey: [participantIdentity: publication.sid])
                } else {
                    // The deferred attach has not landed yet; tombstone the sid so it skips.
                    $0.staleSids.insert(publication.sid)
                }
            }
        }
    }
}

// MARK: - Data Packet encryption

extension E2EEManager {
    func encrypt(data: Data) throws -> LKRTCEncryptedPacket {
        guard let room = _room,
              let identity = room.localParticipant.identity?.stringValue
        else {
            throw LiveKitError(.invalidState, message: "Room or participant identity is nil")
        }

        guard let cryptor = _state.dataCryptor else {
            throw LiveKitError(.invalidState, message: "Cryptor is nil")
        }

        let keyIndex = UInt32(keyProvider.getCurrentKeyIndex())
        guard let encryptedData = cryptor.encrypt(identity, keyIndex: keyIndex, data: data) else {
            throw LiveKitError(.encryptionFailed, message: "Failed to encrypt data packet")
        }

        return encryptedData
    }

    func handle(encryptedData: LKRTCEncryptedPacket, participantIdentity: String) throws -> Data {
        guard let cryptor = _state.dataCryptor else {
            throw LiveKitError(.invalidState, message: "Cryptor is nil")
        }

        guard let decryptedData = cryptor.decrypt(participantIdentity, encryptedPacket: encryptedData) else {
            throw LiveKitError(.decryptionFailed, message: "Failed to decrypt data packet")
        }

        return decryptedData
    }
}
