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

final class ByteStreamReaderTests: @unchecked Sendable {
    private var continuation: StreamReaderSource.Continuation!
    private var reader: ByteStreamReader!

    private let testInfo = ByteStreamInfo(
        id: UUID().uuidString,
        topic: "someTopic",
        timestamp: Date(),
        totalLength: nil,
        attributes: [:],
        encryptionType: .none,
        mimeType: "application/octet-stream",
        name: "filename.bin"
    )

    let testChunks = [
        Data(repeating: 0xAB, count: 128),
        Data(repeating: 0xCD, count: 128),
        Data(repeating: 0xEF, count: 256),
        Data(repeating: 0x12, count: 32),
    ]

    /// All chunks combined.
    private var testPayload: Data {
        testChunks.reduce(Data()) { $0 + $1 }
    }

    private func sendPayload(closingError: Error? = nil) {
        for chunk in testChunks {
            continuation.yield(chunk)
        }
        continuation.finish(throwing: closingError)
    }

    init() {
        let source = StreamReaderSource {
            self.continuation = $0
        }
        reader = ByteStreamReader(info: testInfo, source: source)
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

    @Test func readToFile() async throws {
        try await confirmation("File properly written") { confirm in
            Task {
                do {
                    let fileURL = try await reader.writeToFile()
                    #expect(fileURL.lastPathComponent == reader.info.name)

                    let fileContents = try Data(contentsOf: fileURL)
                    #expect(fileContents == testPayload)

                    confirm()
                } catch {
                    print(error)
                }
            }
            sendPayload()

            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    @Test func resolveFileName() {
        #expect(
            ByteStreamReader.resolveFileName(
                preferredName: nil,
                fallbackName: "[fallback]",
                mimeType: "text/plain"
            ) == "[fallback].txt",
            "Fallback name should be used when no preferred name is provided"
        )
        #expect(
            ByteStreamReader.resolveFileName(
                preferredName: "name",
                fallbackName: "[fallback]",
                mimeType: "text/plain"
            ) == "name.txt",
            "preferred name should take precedence over fallback name"
        )
        #expect(
            ByteStreamReader.resolveFileName(
                preferredName: "name.jpeg",
                fallbackName: "[fallback]",
                mimeType: "text/plain"
            ) == "name.jpeg",
            "File extension in preferred name should take precedence"
        )
        #expect(
            ByteStreamReader.resolveFileName(
                preferredName: "name",
                fallbackName: "[fallback]",
                mimeType: "image/jpeg"
            ) == "name.jpeg",
            "File extension should be resolved from MIME type"
        )
        #expect(
            ByteStreamReader.resolveFileName(
                preferredName: "name",
                fallbackName: "[fallback]",
                mimeType: "text/invalid"
            ) == "name.bin",
            "Default extension should be used when MIME type is not recognized"
        )
    }
}
