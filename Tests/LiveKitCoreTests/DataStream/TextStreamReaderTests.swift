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

final class TextStreamReaderTests: @unchecked Sendable {
    private var continuation: StreamReaderSource.Continuation!
    private var reader: TextStreamReader!

    private let testInfo = TextStreamInfo(
        id: UUID().uuidString,
        topic: "someTopic",
        timestamp: Date(),
        totalLength: nil,
        attributes: [:],
        encryptionType: .none,
        operationType: .create,
        version: 1,
        replyToStreamID: nil,
        attachedStreamIDs: [],
        generated: false
    )

    let testChunks = [
        String(repeating: "A", count: 128),
        String(repeating: "B", count: 128),
        String(repeating: "C", count: 256),
        String(repeating: "D", count: 32),
    ]

    /// All chunks combined.
    private var testPayload: String {
        testChunks.reduce("") { $0 + $1 }
    }

    private func sendPayload(closingError: Error? = nil) {
        for chunk in testChunks {
            continuation.yield(Data(chunk.utf8))
        }
        continuation.finish(throwing: closingError)
    }

    init() {
        let source = StreamReaderSource {
            self.continuation = $0
        }
        reader = TextStreamReader(info: testInfo, source: source)
    }

    @Test func chunkRead() async throws {
        try await confirmation("Receive all chunks") { receiveConfirm in
            try await confirmation("Normal closure") { closureConfirm in
                Task {
                    var chunkIndex = 0
                    for try await chunk in reader {
                        #expect(chunk == testChunks[chunkIndex])
                        if chunkIndex == testChunks.count - 1 {
                            receiveConfirm()
                        }
                        chunkIndex += 1
                    }
                    closureConfirm()
                }

                sendPayload()

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    @Test func chunkReadError() async throws {
        try await confirmation("Read throws error") { confirm in
            let testError = StreamError.abnormalEnd(reason: "test")

            Task {
                do {
                    for try await _ in reader {}
                } catch {
                    #expect(error as? StreamError == testError)
                    confirm()
                }
            }
            sendPayload(closingError: testError)

            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    @Test func readAll() async throws {
        try await confirmation("Read full payload") { confirm in
            Task {
                let fullPayload = try await reader.readAll()
                #expect(fullPayload == testPayload)
                confirm()
            }
            sendPayload()

            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}
