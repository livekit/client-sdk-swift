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

struct TextStreamInfoTests {
    @Test func protocolTypeConversion() {
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
        #expect(header.streamID == info.id)
        #expect(header.topic == info.topic)
        #expect(header.timestamp == Int64(info.timestamp.timeIntervalSince1970 * TimeInterval(1000)))
        #expect(header.totalLength == UInt64(info.totalLength ?? -1))
        #expect(header.attributes == info.attributes)
        #expect(header.encryptionType.rawValue == info.encryptionType.rawValue)
        #expect(header.textHeader.operationType.rawValue == info.operationType.rawValue)
        #expect(header.textHeader.version == Int32(info.version))
        #expect(header.textHeader.replyToStreamID == info.replyToStreamID)
        #expect(header.textHeader.attachedStreamIds == info.attachedStreamIDs)
        #expect(header.textHeader.generated == info.generated)

        let newInfo = TextStreamInfo(header, header.textHeader, .gcm)
        #expect(newInfo.id == info.id)
        #expect(newInfo.topic == info.topic)
        #expect(newInfo.timestamp == info.timestamp)
        #expect(newInfo.totalLength == info.totalLength)
        #expect(newInfo.attributes == info.attributes)
        #expect(newInfo.encryptionType == info.encryptionType)
        #expect(newInfo.operationType == info.operationType)
        #expect(newInfo.version == info.version)
        #expect(newInfo.replyToStreamID == info.replyToStreamID)
        #expect(newInfo.attachedStreamIDs == info.attachedStreamIDs)
        #expect(newInfo.generated == info.generated)
    }
}
