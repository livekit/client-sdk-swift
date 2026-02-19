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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

struct OutgoingStreamManagerTests {
    @Test func streamBytes() async throws {
        let testChunks = [
            Data(repeating: 0xAB, count: 128),
            Data(repeating: 0xCD, count: 128),
            Data(repeating: 0xEF, count: 256),
            Data(repeating: 0x12, count: 32),
        ]
        let streamID = UUID().uuidString
        let topic = "some-topic"

        let counter = ConcurrentCounter()

        try await confirmation("Produces header packet") { headerConfirm in
            try await confirmation("Produces chunk packets") { chunkConfirm in
                try await confirmation("Produces trailer packet") { trailerConfirm in
                    let manager = OutgoingStreamManager { packet in
                        // Simulate data channel send
                        try await Task.sleep(nanoseconds: 10_000_000)

                        switch packet.value {
                        case let .streamHeader(header):
                            #expect(header.streamID == streamID)
                            #expect(header.topic == topic)
                            #expect(header.mimeType == "application/octet-stream")

                            headerConfirm()

                        case let .streamChunk(chunk):
                            let currentChunk = await counter.increment()
                            #expect(chunk.streamID == streamID)
                            #expect(chunk.chunkIndex == UInt64(currentChunk))
                            #expect(chunk.content == testChunks[currentChunk])

                            if await counter.getCount() == testChunks.count {
                                chunkConfirm()
                            }

                        case let .streamTrailer(trailer):
                            #expect(trailer.streamID == streamID)
                            #expect(trailer.reason == "")

                            trailerConfirm()

                        default: Issue.record("Produced unexpected packet type")
                        }
                    } encryptionProvider: {
                        .none
                    }

                    let writer = try await manager.streamBytes(
                        options: StreamByteOptions(topic: topic, id: streamID)
                    )

                    for chunk in testChunks {
                        try await writer.write(chunk)
                    }
                    try await writer.close()

                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    @Test func streamText() async throws {
        let testChunks = [
            String(repeating: "A", count: 128),
            String(repeating: "B", count: 128),
            String(repeating: "C", count: 256),
            String(repeating: "D", count: 32),
        ]
        let streamID = UUID().uuidString
        let topic = "some-topic"

        let counter = ConcurrentCounter()

        try await confirmation("Produces header packet") { headerConfirm in
            try await confirmation("Produces chunk packets") { chunkConfirm in
                try await confirmation("Produces trailer packet") { trailerConfirm in
                    let manager = OutgoingStreamManager { packet in
                        // Simulate data channel send
                        try await Task.sleep(nanoseconds: 10_000_000)

                        switch packet.value {
                        case let .streamHeader(header):
                            #expect(header.streamID == streamID)
                            #expect(header.topic == topic)
                            #expect(header.mimeType == "text/plain")

                            headerConfirm()

                        case let .streamChunk(chunk):
                            let currentChunk = await counter.increment()
                            #expect(chunk.streamID == streamID)
                            #expect(chunk.chunkIndex == UInt64(currentChunk))
                            #expect(chunk.content == Data(testChunks[currentChunk].utf8))

                            if await counter.getCount() == testChunks.count {
                                chunkConfirm()
                            }

                        case let .streamTrailer(trailer):
                            #expect(trailer.streamID == streamID)
                            #expect(trailer.reason == "")

                            trailerConfirm()

                        default: Issue.record("Produced unexpected packet type")
                        }
                    } encryptionProvider: {
                        .none
                    }

                    let writer = try await manager.streamText(
                        options: StreamTextOptions(topic: topic, id: streamID)
                    )

                    for chunk in testChunks {
                        try await writer.write(chunk)
                    }
                    try await writer.close()

                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    @Test func errorPropagation() async throws {
        let testError = LiveKitError(.cancelled, message: "Test error")

        try await confirmation("Error propagates to caller") { confirm in
            let manager = OutgoingStreamManager { packet in
                switch packet.value {
                case .streamChunk:
                    // Wait until first chunk to produce error
                    throw testError
                default: break
                }
            } encryptionProvider: {
                .none
            }

            let writer = try await manager.streamText(
                options: StreamTextOptions(topic: "some-topic")
            )
            do {
                try await writer.write("Hello, world!")
            } catch {
                #expect(error as? LiveKitError == testError)
                confirm()
            }

            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}
