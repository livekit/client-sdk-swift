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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

class AsyncFileStreamTests: LKTestCase {
    private let testBuffer = generateTestBuffer(
        chunkSize: 4096,
        chunkCount: 10,
        extraBytes: 100
    )

    func testNonExistentFile() async throws {
        do {
            _ = try AsyncFileStream(
                readingFrom: URL(fileURLWithPath: "/non/existent/file")
            )
            XCTFail("Expected error")
        } catch {
            XCTAssertNotNil(error as? AsyncFileStream<ReadMode>.Error)
        }
    }

    func testRead() async throws {
        let testFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try testBuffer.write(to: testFileURL)

        defer { try? FileManager.default.removeItem(at: testFileURL) }

        let stream = try AsyncFileStream(readingFrom: testFileURL)

        var readBuffer = Data()
        for try await chunk in stream.chunks() {
            readBuffer.append(chunk)
        }
        XCTAssertEqual(readBuffer, testBuffer)
    }

    func testWrite() async throws {
        let testFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: testFileURL) }

        let stream = try AsyncFileStream(writingTo: testFileURL)
        try await stream.write(testBuffer)
        stream.close()

        let readBuffer = try Data(contentsOf: testFileURL)
        XCTAssertEqual(readBuffer, testBuffer)
    }

    private static func generateTestBuffer(chunkSize: Int, chunkCount: Int, extraBytes: Int) -> Data {
        Data(repeating: 0xFF, count: (chunkSize * chunkCount) + extraBytes)
    }
}
