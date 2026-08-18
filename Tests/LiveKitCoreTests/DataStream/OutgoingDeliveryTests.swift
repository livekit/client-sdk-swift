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
import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// The outgoing delegate is `async`, so a transport failure propagates back to the call that caused
/// it. While it returned `Void` neither of these held: a failed send was swallowed, `write` resolved
/// as if it had succeeded, and `isOpen` stayed `true` on a stream that could no longer be written.
@Suite(.serialized, .tags(.dataStream, .e2e))
struct OutgoingDeliveryTests {
    @Test func writeFailsAndClosesStreamWhenTransportIsGone() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let sender = rooms[1]
            let writer = try await sender.localParticipant.streamBytes(options: StreamByteOptions(topic: "delivery"))

            try await writer.write(Data(repeating: 0x01, count: 1024))
            await #expect(writer.isOpen)

            await sender.disconnect()

            await #expect(throws: StreamError.terminated) {
                try await writer.write(Data(repeating: 0x02, count: 1024))
            }
            await #expect(!writer.isOpen)
        }
    }
}
