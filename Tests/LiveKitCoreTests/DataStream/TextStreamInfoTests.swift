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

class TextStreamInfoTests: LKTestCase {
    func testProtocolTypeConversion() {
        let info = TextStreamInfo(
            id: "id",
            topic: "topic",
            timestamp: Date(timeIntervalSince1970: 100),
            totalLength: 128,
            attributes: ["key": "value"],
            encryptionType: .gcm,
            operationType: .reaction,
            version: 10,
            replyToStreamID: "replyID",
            attachedStreamIDs: ["attachedID"],
            generated: true
        )
        let header = Livekit_DataStream.Header(info)
        XCTAssertEqual(header.streamID, info.id)
        XCTAssertEqual(header.topic, info.topic)
        XCTAssertEqual(header.timestamp, Int64(info.timestamp.timeIntervalSince1970 * TimeInterval(1000)))
        XCTAssertEqual(header.totalLength, UInt64(info.totalLength ?? -1))
        XCTAssertEqual(header.attributes, info.attributes)
        XCTAssertEqual(header.encryptionType.rawValue, info.encryptionType.rawValue)
        XCTAssertEqual(header.textHeader.operationType.rawValue, info.operationType.rawValue)
        XCTAssertEqual(header.textHeader.version, Int32(info.version))
        XCTAssertEqual(header.textHeader.replyToStreamID, info.replyToStreamID)
        XCTAssertEqual(header.textHeader.attachedStreamIds, info.attachedStreamIDs)
        XCTAssertEqual(header.textHeader.generated, info.generated)

        let newInfo = TextStreamInfo(header, header.textHeader, .gcm)
        XCTAssertEqual(newInfo.id, info.id)
        XCTAssertEqual(newInfo.topic, info.topic)
        XCTAssertEqual(newInfo.timestamp, info.timestamp)
        XCTAssertEqual(newInfo.totalLength, info.totalLength)
        XCTAssertEqual(newInfo.attributes, info.attributes)
        XCTAssertEqual(newInfo.encryptionType, info.encryptionType)
        XCTAssertEqual(newInfo.operationType, info.operationType)
        XCTAssertEqual(newInfo.version, info.version)
        XCTAssertEqual(newInfo.replyToStreamID, info.replyToStreamID)
        XCTAssertEqual(newInfo.attachedStreamIDs, info.attachedStreamIDs)
        XCTAssertEqual(newInfo.generated, info.generated)
    }
}
