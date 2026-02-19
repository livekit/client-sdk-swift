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

import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

struct DataStreamTests {
    private enum Method {
        case send, stream
    }

    @Test func streamText() async throws {
        try await _textDataStream(method: .stream)
    }

    @Test func sendText() async throws {
        try await _textDataStream(method: .send)
    }

    @Test func streamBytes() async throws {
        try await _byteDataStream(method: .stream)
    }

    @Test func sendFile() async throws {
        try await _byteDataStream(method: .send)
    }

    private func _textDataStream(method: Method) async throws {
        let topic = "some-topic"
        let testChunk = "Hello world!"

        try await confirmation("Receives stream chunk") { confirm in
            try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
                let room0 = rooms[0]
                let room1 = rooms[1]

                try await room0.registerTextStreamHandler(for: topic) { reader, participant in
                    #expect(participant == room1.localParticipant.identity)
                    do {
                        let chunk = try await reader.readAll()
                        #expect(chunk == testChunk)
                        confirm()
                    } catch {
                        Issue.record("Read failed: \(error.localizedDescription)")
                    }
                }

                do {
                    switch method {
                    case .send:
                        try await room1.localParticipant.sendText(testChunk, for: topic)
                    case .stream:
                        let writer = try await room1.localParticipant.streamText(for: topic)
                        try await writer.write(testChunk)
                        try await writer.close()
                    }
                } catch {
                    Issue.record("Write failed: \(error.localizedDescription)")
                }

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func _byteDataStream(method: Method) async throws {
        let topic = "some-topic"
        let testChunk = Data(repeating: 0xFF, count: 256)

        try await confirmation("Receives stream chunk") { confirm in
            try await TestEnvironment.withRooms([RoomTestingOptions(canSubscribe: true), RoomTestingOptions(canPublishData: true)]) { rooms in
                let room0 = rooms[0]
                let room1 = rooms[1]

                try await room0.registerByteStreamHandler(for: topic) { reader, participant in
                    #expect(participant == room1.localParticipant.identity)
                    do {
                        let chunk = try await reader.readAll()
                        #expect(chunk == testChunk)
                        confirm()
                    } catch {
                        Issue.record("Read failed: \(error.localizedDescription)")
                    }
                }

                do {
                    switch method {
                    case .send:
                        // Only sending files is supported, write chunk to file first
                        let fileURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("file-name.pdf")
                        try testChunk.write(to: fileURL)

                        let info = try await room1.localParticipant.sendFile(fileURL, for: topic)

                        #expect(info.name == fileURL.lastPathComponent)
                        #expect(info.mimeType == "application/pdf")
                        #expect(info.totalLength == testChunk.count)

                    case .stream:
                        let writer = try await room1.localParticipant.streamBytes(for: topic)
                        try await writer.write(testChunk)
                        try await writer.close()
                    }
                } catch {
                    Issue.record("Write failed: \(error.localizedDescription)")
                }

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}
