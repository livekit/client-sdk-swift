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

class ByteStreamInfoTests: LKTestCase {
    func testProtocolTypeConversion() {
        let info = ByteStreamInfo(
            id: "id",
            topic: "topic",
            timestamp: Date(timeIntervalSince1970: 100),
            totalLength: 128,
            attributes: ["key": "value"],
            encryptionType: .gcm,
            mimeType: "image/jpeg",
            name: "filename.bin"
        )
        let header = Livekit_DataStream.Header(info)
        XCTAssertEqual(header.streamID, info.id)
        XCTAssertEqual(header.mimeType, info.mimeType)
        XCTAssertEqual(header.topic, info.topic)
        XCTAssertEqual(header.timestamp, Int64(info.timestamp.timeIntervalSince1970 * TimeInterval(1000)))
        XCTAssertEqual(header.totalLength, UInt64(info.totalLength ?? -1))
        XCTAssertEqual(header.attributes, info.attributes)
        XCTAssertEqual(header.encryptionType.rawValue, info.encryptionType.rawValue)
        XCTAssertEqual(header.byteHeader.name, info.name)

        let newInfo = ByteStreamInfo(header, header.byteHeader, .gcm)
        XCTAssertEqual(newInfo.id, info.id)
        XCTAssertEqual(newInfo.mimeType, info.mimeType)
        XCTAssertEqual(newInfo.topic, info.topic)
        XCTAssertEqual(newInfo.timestamp, info.timestamp)
        XCTAssertEqual(newInfo.totalLength, info.totalLength)
        XCTAssertEqual(newInfo.attributes, info.attributes)
        XCTAssertEqual(newInfo.encryptionType, info.encryptionType)
        XCTAssertEqual(newInfo.name, info.name)
    }
}
