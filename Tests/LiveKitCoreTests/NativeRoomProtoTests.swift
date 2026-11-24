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
import LiveKitFFI
import Testing

struct NativeRoomProtoTests {
    @Test
    func snapshotPreservesMillisecondsAndPublicationOwnership() throws {
        let nativeRoom = NativeRoomInfo(sid: nil, name: "room", metadata: "metadata",
                                        numParticipants: 2, numPublishers: 1, maxParticipants: 8,
                                        activeRecording: true, emptyTimeout: 300, departureTimeout: 20,
                                        creationTime: 1_700_000_000_123)
        let room = try Livekit_Room(serializedBytes: nativeRoom.toPBType().serializedData())
        #expect(!room.hasSid)
        #expect(room.creationTimeMs == 1_700_000_000_123)
        #expect(room.creationTime == 0)
        #expect(room.activeRecording)

        let participant = NativeParticipant(identity: "alice", sid: "PA_alice", isLocal: false,
                                            name: "Alice", state: .active, kind: .bridge,
                                            kindDetails: [.bridgeRtsp], metadata: "", attributes: [:],
                                            isSpeaking: false, audioLevel: 0, connectionQuality: .excellent,
                                            joinedAt: 1_700_000_000_456, permission: nil, isEncrypted: false,
                                            disconnectReason: .unknownReason, clientProtocol: 2, capabilities: [.packetTrailer])
        let own = NativeTrackPublication(sid: "TR_alice", participantIdentity: "alice", name: "screen",
                                         kind: .video, source: .screenshare, isMuted: false,
                                         simulcasted: true, width: 1920, height: 1080,
                                         mimeType: "video/VP8", encryptionType: .gcm, remote: nil)
        var other = own
        other.participantIdentity = "bob"
        other.sid = "TR_bob"
        let info = try Livekit_ParticipantInfo(serializedBytes: participant.toPBType(publications: [other, own]).serializedData())
        #expect(info.joinedAtMs == participant.joinedAt)
        #expect(info.kind == .bridge)
        #expect(info.kindDetails == [.bridgeRtsp])
        #expect(info.clientProtocol == 2)
        #expect(!info.hasPermission)
        #expect(info.tracks.map(\.sid) == ["TR_alice"])
        let track = try #require(info.tracks.first)
        #expect(track.source == .screenShare)
        #expect(track.encryption == .gcm)
    }
}
