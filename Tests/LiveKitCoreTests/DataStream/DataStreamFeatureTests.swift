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

/// Stream features between real rooms that the Rust core carries end to end.
extension DataStreamTests {
    /// The attributes a sender sets when it closes a stream reach the receiver's info once the
    /// stream has ended, and replace header attributes with the same key.
    @Test(arguments: [false, true])
    func closeAttributesReachTheReceiver(text: Bool) async throws {
        let header = ["kept": "header", "replaced": "header"]
        let trailer = ["replaced": "trailer", "added": "trailer"]

        try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
            let (receiver, sender) = (rooms[0], rooms[1])
            let received = AsyncCompleter<[String: String]>(label: "Attributes after the end", defaultTimeout: 30)
            if text {
                try await receiver.registerTextStreamHandler(for: "attributes") { reader, _ in
                    do {
                        _ = try await reader.readAll()
                        received.resume(returning: reader.info.attributes)
                    } catch {
                        received.resume(throwing: error)
                    }
                }
                let writer = try await sender.localParticipant.streamText(options: StreamTextOptions(topic: "attributes", attributes: header))
                try await writer.write("hello")
                try await writer.close(attributes: trailer)
            } else {
                try await receiver.registerByteStreamHandler(for: "attributes") { reader, _ in
                    do {
                        _ = try await reader.readAll()
                        received.resume(returning: reader.info.attributes)
                    } catch {
                        received.resume(throwing: error)
                    }
                }
                let writer = try await sender.localParticipant.streamBytes(options: StreamByteOptions(topic: "attributes", attributes: header))
                try await writer.write(Data("hello".utf8))
                try await writer.close(attributes: trailer)
            }

            #expect(try await received.wait() == ["kept": "header", "replaced": "trailer", "added": "trailer"])
        }
    }
}
