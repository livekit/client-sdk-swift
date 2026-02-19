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
struct FileInfoTests {
    @Test(arguments: ["text/plain", "application/json", "image/jpeg", "application/pdf"])
    func readInfo(mimeType: String) throws {
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
        #expect(FileInfo(for: fileURL) == expectedInfo)
    }

    @Test func readInfoUnreadable() {
        #expect(FileInfo(for: URL(fileURLWithPath: "/some/unreadable/path")) == nil)
    }

    @Test(arguments: [
        ("text/plain", "txt"),
        ("application/octet-stream", "bin"),
        ("application/json", "json"),
        ("image/jpeg", "jpeg"),
        ("application/pdf", "pdf"),
    ])
    func preferredExtension(mimeType: String, expected: String) {
        #expect(FileInfo.preferredExtension(for: mimeType) == expected)
    }

    @Test(arguments: ["text/invalid", ""])
    func preferredExtensionInvalid(mimeType: String) {
        #expect(FileInfo.preferredExtension(for: mimeType) == nil)
    }
}
