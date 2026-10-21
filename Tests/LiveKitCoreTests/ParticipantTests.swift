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

import Foundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.serialized, .tags(.e2e), TestLimits.e2e)
struct ParticipantTests {
    @Test(arguments: [(Int32(-1), ClientProtocol.v0), (0, .v0), (1, .v1), (2, .v2), (3, .v2), (.max, .v2)])
    func remoteClientProtocol(advertised: Int32, expected: ClientProtocol) {
        let info = Livekit_ParticipantInfo.with {
            $0.identity = "remote"
            $0.clientProtocol = advertised
        }
        let participant = RemoteParticipant(info: info, room: Room(), connectionState: .connected)
        #expect(participant.clientProtocol == expected)
    }

    /// Capabilities come from the participant info: none by default, both known ones, and nothing
    /// for the protocol's placeholder or a value this SDK does not know.
    @Test(arguments: [
        ([Livekit_ClientInfo_Capability](), [ClientCapability]()),
        ([.capCompressionDeflateRaw, .capPacketTrailer], [.compressionDeflateRaw, .packetTrailer]),
        ([.capUnused, Livekit_ClientInfo_Capability(rawValue: 9999), .capCompressionDeflateRaw], [.compressionDeflateRaw]),
    ])
    func remoteCapabilities(advertised: [Livekit_ClientInfo_Capability], expected: [ClientCapability]) {
        let participant = RemoteParticipant(info: info(capabilities: advertised), room: Room(), connectionState: .connected)
        #expect(participant.capabilities == expected)
    }

    /// A later update replaces the capabilities, so one without any clears them.
    @Test func remoteCapabilitiesClearedByLaterUpdate() {
        let participant = RemoteParticipant(info: info(capabilities: [.capCompressionDeflateRaw]), room: Room(), connectionState: .connected)
        #expect(participant.capabilities == [.compressionDeflateRaw])

        participant.set(info: info(capabilities: []), connectionState: .connected)
        #expect(participant.capabilities.isEmpty)
    }

    private func info(capabilities: [Livekit_ClientInfo_Capability]) -> Livekit_ParticipantInfo {
        Livekit_ParticipantInfo.with {
            $0.identity = "remote"
            $0.capabilities = capabilities
        }
    }

    @Test func localParticipantIdentity() async throws {
        try await TestEnvironment.withRoom { room in
            #expect(room.localParticipant.identity != nil, "LocalParticipant's identity is nil")

            print("room.localParticipant.identity: \(String(describing: room.localParticipant.identity))")
        }
    }

    @Test func remoteParticipants() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(), RoomTestingOptions(), RoomTestingOptions()]) { rooms in
            // Alias to Room
            let room1 = rooms[0]
            let room2 = rooms[1]
            let room3 = rooms[2]

            #expect(room1.remoteParticipants.count == 2, "Remote participant count must be 2")
            #expect(room2.remoteParticipants.count == 2, "Remote participant count must be 2")
            #expect(room3.remoteParticipants.count == 2, "Remote participant count must be 2")

            print("room1.remoteParticipants: \(String(describing: room1.remoteParticipants))")
            print("room2.remoteParticipants: \(String(describing: room2.remoteParticipants))")
            print("room2.remoteParticipants: \(String(describing: room3.remoteParticipants))")
        }
    }
}
