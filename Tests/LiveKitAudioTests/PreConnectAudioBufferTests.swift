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

@Suite(.serialized) struct PreConnectAudioBufferTests {
    @Test func participantActiveStateSendsAudioData() async throws {
        try await confirmation("Receives audio data") { confirm in
            try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublish: true, canPublishData: true)]) { rooms in
                let subscriberRoom = rooms[0]
                let publisherRoom = rooms[1]

                try await subscriberRoom.registerByteStreamHandler(for: PreConnectAudioBuffer.dataTopic) { reader, participant in
                    #expect(participant == publisherRoom.localParticipant.identity)
                    do {
                        let data = try await reader.readAll()
                        #expect(!data.isEmpty, "Received audio data should not be empty")
                        confirm()
                    } catch {
                        Issue.record("Read failed: \(error.localizedDescription)")
                    }
                }

                let buffer = PreConnectAudioBuffer(room: publisherRoom)

                try await buffer.startRecording()
                try await Task.sleep(nanoseconds: NSEC_PER_SEC / 2)

                subscriberRoom.localParticipant._state.mutate { $0.kind = .agent } // override kind
                buffer.room(publisherRoom, participant: subscriberRoom.localParticipant, didUpdateState: .active)

                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }
}
