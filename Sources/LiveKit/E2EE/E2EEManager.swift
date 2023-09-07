/*
 * Copyright 2022 LiveKit
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
import WebRTC

@objc
public class E2EEManager: NSObject, ObservableObject, Loggable {
    // Reference to Room
    internal weak var room: Room?
    internal var enabled: Bool = true
    public var e2eeOptions: E2EEOptions
    internal var frameCryptors = [[String: Sid]: RTCFrameCryptor]()
    internal var trackPublications = [RTCFrameCryptor: TrackPublication]()

    public init(e2eeOptions: E2EEOptions) {
        self.e2eeOptions = e2eeOptions
    }

    public func keyProvider() -> BaseKeyProvider {
        return self.e2eeOptions.keyProvider
    }

    public func getFrameCryptors() -> [[String: Sid]: RTCFrameCryptor] {
        return self.frameCryptors
    }

    public func setup(room: Room) {
        if self.room != room {
            cleanUp()
        }
        self.room = room
        self.room?.delegates.add(delegate: self)
        self.room?.localParticipant?.tracks.forEach({ (_: Sid, publication: TrackPublication) in
            if publication.encryptionType == EncryptionType.none {
                self.log("E2EEManager::setup: local participant \(self.room!.localParticipant!.identity) track \(publication.sid) encryptionType is none, skip")
                return
            }
            let fc = addRtpSender(sender: publication.track!.rtpSender!, participantId: self.room!.localParticipant!.identity, trackSid: publication.sid)
            trackPublications[fc] = publication
        })

        self.room?.remoteParticipants.forEach({ (_: Sid, participant: RemoteParticipant) in
            participant.tracks.forEach({ (_: Sid, publication: TrackPublication) in
                if publication.encryptionType == EncryptionType.none {
                    self.log("E2EEManager::setup: remote participant \(participant.identity) track \(publication.sid) encryptionType is none, skip")
                    return
                }
                let fc = addRtpReceiver(receiver: publication.track!.rtpReceiver!, participantId: participant.identity, trackSid: publication.sid)
                trackPublications[fc] = publication
            })
        })
    }

    public func enableE2EE(enabled: Bool) {
        self.enabled = enabled
        for (_, frameCryptor) in frameCryptors {
            frameCryptor.enabled = enabled
        }
    }

    func addRtpSender(sender: RTCRtpSender, participantId: String, trackSid: Sid) -> RTCFrameCryptor {
        self.log("addRtpSender \(participantId) to E2EEManager")
        let frameCryptor = RTCFrameCryptor(rtpSender: sender, participantId: participantId, algorithm: RTCCyrptorAlgorithm.aesGcm, keyProvider: self.e2eeOptions.keyProvider.rtcKeyProvider!)
        frameCryptor.delegate = self
        frameCryptors[[participantId: trackSid]] = frameCryptor
        frameCryptor.enabled = self.enabled
        return frameCryptor
    }

    func addRtpReceiver(receiver: RTCRtpReceiver, participantId: String, trackSid: Sid) -> RTCFrameCryptor {
        self.log("addRtpReceiver \(participantId)  to E2EEManager")
        let frameCryptor = RTCFrameCryptor(rtpReceiver: receiver, participantId: participantId, algorithm: RTCCyrptorAlgorithm.aesGcm, keyProvider: self.e2eeOptions.keyProvider.rtcKeyProvider!)
        frameCryptor.delegate = self
        frameCryptors[[participantId: trackSid]] = frameCryptor
        frameCryptor.enabled = self.enabled
        return frameCryptor
    }

    public func cleanUp() {
        self.room?.delegates.remove(delegate: self)
        for (_, frameCryptor) in frameCryptors {
            frameCryptor.delegate = nil
        }
        frameCryptors.removeAll()
        trackPublications.removeAll()
    }
}

extension E2EEManager: RTCFrameCryptorDelegate {

    public func frameCryptor(_ frameCryptor: RTCFrameCryptor, didStateChangeWithParticipantId participantId: String, with state: FrameCryptionState) {
        self.log("frameCryptor didStateChangeWithParticipantId \(participantId) with state \(state.rawValue)")
        let publication: TrackPublication? = trackPublications[frameCryptor]
        if publication == nil {
            self.log("frameCryptor didStateChangeWithParticipantId \(participantId) with state \(state.rawValue) publication is nil")
            return
        }
        if self.room == nil {
            self.log("frameCryptor didStateChangeWithParticipantId \(participantId) with state \(state.rawValue) room is nil")
            return

        }
        self.room?.delegates.notify { delegate in
            delegate.room?(self.room!, publication: publication!, didUpdateE2EEState: state.toLKType())
        }
    }
}

extension E2EEManager: RoomDelegate {

    public func room(_ room: Room, localParticipant: LocalParticipant, didPublish publication: LocalTrackPublication) {
        if publication.encryptionType == EncryptionType.none {
            self.log("E2EEManager::RoomDelegate: local participant \(localParticipant.identity) track \(publication.sid) encryptionType is none, skip")
            return
        }
        let fc = addRtpSender(sender: localParticipant.rtpSender!, participantId: localParticipant.identity, trackSid: publication.sid)
        trackPublications[fc] = publication
    }

    public func room(_ room: Room, localParticipant: LocalParticipant, didUnpublish publication: LocalTrackPublication) {
        let frameCryptor = frameCryptors.first(where: { (key: [String: Sid], _: RTCFrameCryptor) -> Bool in
            return key[localParticipant.identity] == publication.sid
        })?.value

        frameCryptor?.delegate = nil
        frameCryptor?.enabled = false
        frameCryptors.removeValue(forKey: [localParticipant.identity: publication.sid])

        if frameCryptor != nil {
            trackPublications.removeValue(forKey: frameCryptor!)
        }
    }

    public func room(_ room: Room, participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track: Track) {
        if publication.encryptionType == EncryptionType.none {
            self.log("E2EEManager::RoomDelegate: remote participant \(participant.identity) track \(publication.sid) encryptionType is none, skip")
            return
        }
        let fc = addRtpReceiver(receiver: participant.rtpReceiver!, participantId: participant.identity, trackSid: publication.sid)
        trackPublications[fc] = publication
    }

    public func room(_ room: Room, participant: RemoteParticipant, didUnsubscribe publication: RemoteTrackPublication, track: Track) {
        let frameCryptor = frameCryptors.first(where: { (key: [String: Sid], _: RTCFrameCryptor) -> Bool in
            return key[participant.identity] == publication.sid
        })?.value

        frameCryptor?.delegate = nil
        frameCryptor?.enabled = false
        frameCryptors.removeValue(forKey: [participant.identity: publication.sid])

        if frameCryptor != nil {
            trackPublications.removeValue(forKey: frameCryptor!)
        }
    }
}
