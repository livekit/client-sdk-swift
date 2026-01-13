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

class FileInfoTests: LKTestCase {
    func testReadInfo() throws {
        try testReadInfo(mimeType: "text/plain")
        try testReadInfo(mimeType: "application/json")
        try testReadInfo(mimeType: "image/jpeg")
        try testReadInfo(mimeType: "application/pdf")
    }

    private func testReadInfo(
        mimeType: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(FileInfo.preferredExtension(for: mimeType) ?? "")

        let contents = Data(repeating: 0xFF, count: 32)
        try contents.write(to: fileURL)

        let expectedInfo = FileInfo(
            name: fileURL.lastPathComponent,
            size: contents.count,
            mimeType: mimeType
        )
        XCTAssertEqual(FileInfo(for: fileURL), expectedInfo, file: file, line: line)
    }

    func testReadInfoUnreadable() {
        XCTAssertNil(FileInfo(for: URL(fileURLWithPath: "/some/unreadable/path")))
    }

    func testPreferredExtensionCommon() {
        XCTAssertEqual(FileInfo.preferredExtension(for: "text/plain"), "txt")
        XCTAssertEqual(FileInfo.preferredExtension(for: "application/octet-stream"), "bin")
        XCTAssertEqual(FileInfo.preferredExtension(for: "application/json"), "json")
        XCTAssertEqual(FileInfo.preferredExtension(for: "image/jpeg"), "jpeg")
        XCTAssertEqual(FileInfo.preferredExtension(for: "application/pdf"), "pdf")
    }

    func testPreferredExtensionInvalid() {
        XCTAssertNil(FileInfo.preferredExtension(for: "text/invalid"))
        XCTAssertNil(FileInfo.preferredExtension(for: ""))
    }
}
