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

@Suite(.tags(.dataStream))
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

    @Test func chunkRead() async {
        await confirmation("Receive all chunks") { receiveConfirm in
            await confirmation("Normal closure") { closureConfirm in
                let processingTask = Task {
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

                _ = await processingTask.result
            }
        }
    }

    @Test func chunkReadError() async {
        await confirmation("Read throws error") { confirm in
            let testError = StreamError.abnormalEnd(reason: "test")

            let processingTask = Task {
                do {
                    for try await _ in reader {}
                } catch {
                    #expect(error as? StreamError == testError)
                    confirm()
                }
            }
            sendPayload(closingError: testError)

            _ = await processingTask.result
        }
    }

    @Test func readAll() async {
        await confirmation("Read full payload") { confirm in
            let processingTask = Task {
                let fullPayload = try await reader.readAll()
                #expect(fullPayload == testPayload)
                confirm()
            }
            sendPayload()

            _ = await processingTask.result
        }
    }

    @Test func readToFile() async {
        await confirmation("File properly written") { confirm in
            let processingTask = Task {
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

            _ = await processingTask.result
        }
    }

    struct FileNameCase: CustomTestStringConvertible {
        let preferred: String?
        let fallback: String
        let mimeType: String
        let expected: String
        var testDescription: String { "preferred=\(preferred ?? "nil"), mime=\(mimeType) → \(expected)" }
    }

    @Test(arguments: [
        FileNameCase(preferred: nil, fallback: "[fallback]", mimeType: "text/plain", expected: "[fallback].txt"),
        FileNameCase(preferred: "name", fallback: "[fallback]", mimeType: "text/plain", expected: "name.txt"),
        FileNameCase(preferred: "name.jpeg", fallback: "[fallback]", mimeType: "text/plain", expected: "name.jpeg"),
        FileNameCase(preferred: "name", fallback: "[fallback]", mimeType: "image/jpeg", expected: "name.jpeg"),
        FileNameCase(preferred: "name", fallback: "[fallback]", mimeType: "text/invalid", expected: "name.bin"),
    ])
    func resolveFileName(_ c: FileNameCase) {
        #expect(
            ByteStreamReader.resolveFileName(
                preferredName: c.preferred,
                fallbackName: c.fallback,
                mimeType: c.mimeType
            ) == c.expected
        )
    }
}
