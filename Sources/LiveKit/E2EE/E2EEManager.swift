/*
 * Copyright 2023 LiveKit
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

    // Reference to Room
    weak var room: Room?
    var enabled: Bool = true
    public var e2eeOptions: E2EEOptions
    var frameCryptors = [[String: Sid]: LKRTCFrameCryptor]()
    var trackPublications = [LKRTCFrameCryptor: TrackPublication]()
    private lazy var delegateAdapter: DelegateAdapter = .init(target: self)

    public init(e2eeOptions: E2EEOptions) {
        self.e2eeOptions = e2eeOptions
    }

    public func keyProvider() -> BaseKeyProvider {
        e2eeOptions.keyProvider
    }

    func getFrameCryptors() -> [[String: Sid]: LKRTCFrameCryptor] {
        frameCryptors
    }

    public func setup(room: Room) {
        if self.room != room {
            cleanUp()
        }
        self.room = room
        self.room?.delegates.add(delegate: self)
        self.room?.localParticipant.tracks.forEach { (_: Sid, publication: TrackPublication) in
            if publication.encryptionType == EncryptionType.none {
                self.log("E2EEManager::setup: local participant \(self.room!.localParticipant.sid) track \(publication.sid) encryptionType is none, skip")
                return
            }
            if publication.track?.rtpSender == nil {
                self.log("E2EEManager::setup: publication.track?.rtpSender is nil, skip to create FrameCryptor!")
                return
            }
            let fc = addRtpSender(sender: publication.track!.rtpSender!, participantSid: self.room!.localParticipant.sid, trackSid: publication.sid)
            trackPublications[fc] = publication
        }

        self.room?.remoteParticipants.forEach { (_: Sid, participant: RemoteParticipant) in
            participant.tracks.forEach { (_: Sid, publication: TrackPublication) in
                if publication.encryptionType == EncryptionType.none {
                    self.log("E2EEManager::setup: remote participant \(participant.sid) track \(publication.sid) encryptionType is none, skip")
                    return
                }
                if publication.track?.rtpReceiver == nil {
                    self.log("E2EEManager::setup: publication.track?.rtpReceiver is nil, skip to create FrameCryptor!")
                    return
                }
                let fc = addRtpReceiver(receiver: publication.track!.rtpReceiver!, participantSid: participant.sid, trackSid: publication.sid)
                trackPublications[fc] = publication
            }
        }
    }

    public func enableE2EE(enabled: Bool) {
        self.enabled = enabled
        for (_, frameCryptor) in frameCryptors {
            frameCryptor.enabled = enabled
        }
    }

    func addRtpSender(sender: LKRTCRtpSender, participantSid: String, trackSid: Sid) -> LKRTCFrameCryptor {
        log("addRtpSender \(participantSid) to E2EEManager")
        let frameCryptor = LKRTCFrameCryptor(factory: Engine.peerConnectionFactory, rtpSender: sender, participantId: participantSid, algorithm: RTCCyrptorAlgorithm.aesGcm, keyProvider: e2eeOptions.keyProvider.rtcKeyProvider!)
        frameCryptor.delegate = delegateAdapter
        frameCryptors[[participantSid: trackSid]] = frameCryptor
        frameCryptor.enabled = enabled
        return frameCryptor
    }

    func addRtpReceiver(receiver: LKRTCRtpReceiver, participantSid: String, trackSid: Sid) -> LKRTCFrameCryptor {
        log("addRtpReceiver \(participantSid)  to E2EEManager")
        let frameCryptor = LKRTCFrameCryptor(factory: Engine.peerConnectionFactory, rtpReceiver: receiver, participantId: participantSid, algorithm: RTCCyrptorAlgorithm.aesGcm, keyProvider: e2eeOptions.keyProvider.rtcKeyProvider!)
        frameCryptor.delegate = delegateAdapter
        frameCryptors[[participantSid: trackSid]] = frameCryptor
        frameCryptor.enabled = enabled
        return frameCryptor
    }

    public func cleanUp() {
        room?.delegates.remove(delegate: self)
        for (_, frameCryptor) in frameCryptors {
            frameCryptor.delegate = nil
        }
        frameCryptors.removeAll()
        trackPublications.removeAll()
    }
}

extension E2EEManager {
    func frameCryptor(_ frameCryptor: LKRTCFrameCryptor, didStateChangeWithParticipantId participantId: String, with state: FrameCryptionState) {
        log("frameCryptor didStateChangeWithParticipantId \(participantId) with state \(state.rawValue)")
        let publication: TrackPublication? = trackPublications[frameCryptor]
        if publication == nil {
            log("frameCryptor didStateChangeWithParticipantId \(participantId) with state \(state.rawValue) publication is nil")
            return
        }
        if room == nil {
            log("frameCryptor didStateChangeWithParticipantId \(participantId) with state \(state.rawValue) room is nil")
            return
        }
        room?.delegates.notify { delegate in
            delegate.room?(self.room!, publication: publication!, didUpdateE2EEState: state.toLKType())
        }
    }
}

extension E2EEManager: RoomDelegate {
    public func room(_: Room, localParticipant: LocalParticipant, didPublish publication: LocalTrackPublication) {
        if publication.encryptionType == EncryptionType.none {
            log("E2EEManager::RoomDelegate: local participant \(String(describing: localParticipant.sid)) track \(publication.sid) encryptionType is none, skip")
            return
        }
        if publication.track?.rtpSender == nil {
            log("E2EEManager::RoomDelegate: publication.track?.rtpSender is nil, skip to create FrameCryptor!")
            return
        }
        let fc = addRtpSender(sender: publication.track!.rtpSender!, participantSid: localParticipant.sid, trackSid: publication.sid)
        trackPublications[fc] = publication
    }

    public func room(_: Room, localParticipant: LocalParticipant, didUnpublish publication: LocalTrackPublication) {
        let frameCryptor = frameCryptors.first(where: { (key: [String: Sid], _: LKRTCFrameCryptor) -> Bool in
            key[localParticipant.sid] == publication.sid
        })?.value

        frameCryptor?.delegate = nil
        frameCryptor?.enabled = false
        frameCryptors.removeValue(forKey: [localParticipant.sid: publication.sid])

        if frameCryptor != nil {
            trackPublications.removeValue(forKey: frameCryptor!)
        }
    }

    public func room(_: Room, participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track _: Track) {
        if publication.encryptionType == EncryptionType.none {
            log("E2EEManager::RoomDelegate: remote participant \(String(describing: participant.sid)) track \(publication.sid) encryptionType is none, skip")
            return
        }
        if publication.track?.rtpReceiver == nil {
            log("E2EEManager::RoomDelegate: publication.track?.rtpReceiver is nil, skip to create FrameCryptor!")
            return
        }
        let fc = addRtpReceiver(receiver: publication.track!.rtpReceiver!, participantSid: participant.sid, trackSid: publication.sid)
        trackPublications[fc] = publication
    }

    public func room(_: Room, participant: RemoteParticipant, didUnsubscribe publication: RemoteTrackPublication, track _: Track) {
        let frameCryptor = frameCryptors.first(where: { (key: [String: Sid], _: LKRTCFrameCryptor) -> Bool in
            key[participant.sid] == publication.sid
        })?.value

        frameCryptor?.delegate = nil
        frameCryptor?.enabled = false
        frameCryptors.removeValue(forKey: [participant.sid: publication.sid])

        if frameCryptor != nil {
            trackPublications.removeValue(forKey: frameCryptor!)
        }
    }
}
