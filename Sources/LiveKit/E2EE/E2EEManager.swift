/*
 * Copyright 2024 LiveKit
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

import Foundation

@_implementationOnly import WebRTC

@objc
public class E2EEManager: NSObject, ObservableObject, Loggable {
    // Private delegate adapter to hide RTCFrameCryptorDelegate symbol
    private class DelegateAdapter: NSObject, LKRTCFrameCryptorDelegate {
        weak var target: E2EEManager?

        init(target: E2EEManager? = nil) {
            self.target = target
        }

        func frameCryptor(_ frameCryptor: LKRTCFrameCryptor,
                          didStateChangeWithParticipantId participantId: String,
                          with stateChanged: FrameCryptionState)
        {
            // Redirect
            target?.frameCryptor(frameCryptor, didStateChangeWithParticipantId: participantId, with: stateChanged)
        }
    }

    // MARK: - Public

    public let e2eeOptions: E2EEOptions

    public var keyProvider: BaseKeyProvider {
        e2eeOptions.keyProvider
    }

    // MARK: - Private

    // Reference to Room
    private weak var _room: Room?

    private lazy var delegateAdapter: DelegateAdapter = .init(target: self)

    private var _state = StateSync(State())

    private struct State: Equatable {
        var enabled: Bool = true
        var frameCryptors = [[String: Sid]: LKRTCFrameCryptor]()
        var trackPublications = [LKRTCFrameCryptor: TrackPublication]()
    }

    public init(e2eeOptions: E2EEOptions) {
        self.e2eeOptions = e2eeOptions
    }

    public func setup(room: Room) {
        if _room != room {
            cleanUp()
        }
        _room = room

        room.delegates.add(delegate: self)

        let localPublications = room.localParticipant.trackPublications.values.compactMap { $0 as? LocalTrackPublication }

        for publication in localPublications {
            addRtpSender(publication: publication, participantSid: room.localParticipant.sid)
        }

        for remoteParticipant in room.remoteParticipants.values {
            let remotePublications = remoteParticipant.trackPublications.values.compactMap { $0 as? RemoteTrackPublication }

            for publication in remotePublications {
                addRtpReceiver(publication: publication, participantSid: remoteParticipant.sid)
            }
        }
    }

    public func enableE2EE(enabled: Bool) {
        _state.mutate {
            $0.enabled = enabled
            for (_, frameCryptor) in $0.frameCryptors {
                frameCryptor.enabled = enabled
            }
        }
    }

    func addRtpSender(publication: LocalTrackPublication, participantSid: String) {
        guard publication.encryptionType != .none else {
            log("encryptionType is .none, skipping creating frame cryptor...", .warning)
            return
        }

        guard let sender = publication.track?.rtpSender else {
            log("sender is nil, skipping creating frame cryptor...", .warning)
            return
        }

        let frameCryptor = LKRTCFrameCryptor(factory: Engine.peerConnectionFactory,
                                             rtpSender: sender,
                                             participantId: participantSid,
                                             algorithm: RTCCyrptorAlgorithm.aesGcm,
                                             keyProvider: e2eeOptions.keyProvider.rtcKeyProvider!)

        frameCryptor.delegate = delegateAdapter

        return _state.mutate {
            $0.frameCryptors[[participantSid: publication.sid]] = frameCryptor
            $0.trackPublications[frameCryptor] = publication
            frameCryptor.enabled = $0.enabled
        }
    }

    func addRtpReceiver(publication: RemoteTrackPublication, participantSid: String) {
        guard publication.encryptionType != .none else {
            log("encryptionType is .none, skipping creating frame cryptor...", .warning)
            return
        }

        guard let receiver = publication.track?.rtpReceiver else {
            log("receiver is nil, skipping creating frame cryptor...", .warning)
            return
        }

        let frameCryptor = LKRTCFrameCryptor(factory: Engine.peerConnectionFactory,
                                             rtpReceiver: receiver,
                                             participantId: participantSid,
                                             algorithm: RTCCyrptorAlgorithm.aesGcm,
                                             keyProvider: e2eeOptions.keyProvider.rtcKeyProvider!)

        frameCryptor.delegate = delegateAdapter

        return _state.mutate {
            $0.frameCryptors[[participantSid: publication.sid]] = frameCryptor
            $0.trackPublications[frameCryptor] = publication
            frameCryptor.enabled = $0.enabled
        }
    }

    public func cleanUp() {
        _room?.delegates.remove(delegate: self)

        _state.mutate {
            for (_, frameCryptor) in $0.frameCryptors {
                frameCryptor.delegate = nil
            }
            $0.frameCryptors.removeAll()
            $0.trackPublications.removeAll()
        }
    }
}

extension E2EEManager {
    func frameCryptor(_ frameCryptor: LKRTCFrameCryptor, didStateChangeWithParticipantId participantId: String, with state: FrameCryptionState) {
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
            delegate.room?(room, track: publication, didUpdateE2EEState: state.toLKType())
        }
    }
}

extension E2EEManager: RoomDelegate {
    public func room(_: Room, localParticipant: LocalParticipant, didPublishPublication publication: LocalTrackPublication) {
        addRtpSender(publication: publication, participantSid: localParticipant.sid)
    }

    public func room(_: Room, localParticipant: LocalParticipant, didUnpublishPublication publication: LocalTrackPublication) {
        _state.mutate {
            if let frameCryptor = ($0.frameCryptors.first { (key: [String: Sid], _: LKRTCFrameCryptor) in
                key[localParticipant.sid] == publication.sid
            })?.value {
                frameCryptor.delegate = nil
                frameCryptor.enabled = false

                $0.trackPublications.removeValue(forKey: frameCryptor)
                $0.frameCryptors.removeValue(forKey: [localParticipant.sid: publication.sid])
            }
        }
    }

    public func room(_: Room, participant: RemoteParticipant, didSubscribePublication publication: RemoteTrackPublication) {
        addRtpReceiver(publication: publication, participantSid: participant.sid)
    }

    public func room(_: Room, participant: RemoteParticipant, didUnsubscribePublication publication: RemoteTrackPublication) {
        _state.mutate {
            if let frameCryptor = ($0.frameCryptors.first { (key: [String: Sid], _: LKRTCFrameCryptor) in
                key[participant.sid] == publication.sid
            })?.value {
                frameCryptor.delegate = nil
                frameCryptor.enabled = false

                $0.trackPublications.removeValue(forKey: frameCryptor)
                $0.frameCryptors.removeValue(forKey: [participant.sid: publication.sid])
            }
        }
    }
}
