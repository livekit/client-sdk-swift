/*
 * Copyright 2025 LiveKit
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
import XCTest

final class StreamInfoTests: XCTestCase {
    
    private func byteStreamInfo(fileName: String?, mimeType: String) -> ByteStreamInfo {
        ByteStreamInfo(
            id: "[streamID]",
            mimeType: mimeType,
            topic: "someTopic",
            timestamp: Date.now,
            totalLength: nil,
            attributes: [:],
            fileName: fileName
        )
    }
    
    func testDefaultFileName() {
        XCTAssertEqual(byteStreamInfo(fileName: "name", mimeType: "text/plain").defaultFileName(), "name.txt")
        XCTAssertEqual(byteStreamInfo(fileName: nil, mimeType: "text/plain").defaultFileName(), "[streamID].txt")
        XCTAssertEqual(byteStreamInfo(fileName: nil, mimeType: "").defaultFileName(), "[streamID].bin")
        XCTAssertEqual(byteStreamInfo(fileName: "name.jpg", mimeType: "text/plain").defaultFileName(), "name.jpg")
        XCTAssertEqual(byteStreamInfo(fileName: "name", mimeType: "text/plain").defaultFileName(override: "altname"), "altname.txt")
    }
}
