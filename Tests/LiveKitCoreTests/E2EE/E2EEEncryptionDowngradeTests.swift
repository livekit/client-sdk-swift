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

@testable import LiveKit
import Testing

@Suite(.tags(.e2ee))
struct E2EEEncryptionDowngradeTests {
    @Test(arguments: [false, true])
    func remoteEncryptionDowngrade(republish: Bool) async throws {
        let room = Room(roomOptions: RoomOptions(encryptionOptions: EncryptionOptions(keyProvider: BaseKeyProvider())))
        let encrypted = Livekit_TrackInfo.with {
            $0.sid = "TR_encrypted"
            $0.type = .video
            $0.source = .camera
            $0.encryption = .gcm
        }
        let initial = Livekit_ParticipantInfo.with {
            $0.sid = "PA_remote"
            $0.identity = "remote"
            $0.tracks = [encrypted]
        }
        let participant = RemoteParticipant(info: initial, room: room, connectionState: .connected)
        let original = try #require(participant.trackPublications[Track.Sid(from: encrypted.sid)] as? RemoteTrackPublication)
        #expect(original.encryptionType == .gcm)

        if republish {
            try await participant.unpublish(publication: original, notify: false)
        }
        let plaintext = Livekit_TrackInfo.with {
            $0.sid = republish ? "TR_republished" : encrypted.sid
            $0.type = .video
            $0.source = .camera
            $0.encryption = .none
        }
        let downgraded = Livekit_ParticipantInfo.with {
            $0.sid = initial.sid
            $0.identity = initial.identity
            $0.tracks = [plaintext]
        }
        participant.set(info: downgraded, connectionState: .connected)

        // addRtpReceiver skips its cryptor when this accepted publication reports .none.
        let accepted = participant.trackPublications[Track.Sid(from: plaintext.sid)]
        #expect(accepted == nil || accepted?.encryptionType != EncryptionType.none,
                "An encrypted participant must reject plaintext publications or retain required decryption, including after republish")
    }
}
