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

struct FileInfoTests {
    @Test func readInfo() throws {
        try _readInfo(mimeType: "text/plain")
        try _readInfo(mimeType: "application/json")
        try _readInfo(mimeType: "image/jpeg")
        try _readInfo(mimeType: "application/pdf")
    }

    private func _readInfo(
        mimeType: String,
        sourceLocation: SourceLocation = #_sourceLocation
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
        #expect(FileInfo(for: fileURL) == expectedInfo, sourceLocation: sourceLocation)
    }

    @Test func readInfoUnreadable() {
        #expect(FileInfo(for: URL(fileURLWithPath: "/some/unreadable/path")) == nil)
    }

    @Test func preferredExtensionCommon() {
        #expect(FileInfo.preferredExtension(for: "text/plain") == "txt")
        #expect(FileInfo.preferredExtension(for: "application/octet-stream") == "bin")
        #expect(FileInfo.preferredExtension(for: "application/json") == "json")
        #expect(FileInfo.preferredExtension(for: "image/jpeg") == "jpeg")
        #expect(FileInfo.preferredExtension(for: "application/pdf") == "pdf")
    }

    @Test func preferredExtensionInvalid() {
        #expect(FileInfo.preferredExtension(for: "text/invalid") == nil)
        #expect(FileInfo.preferredExtension(for: "") == nil)
    }
}
