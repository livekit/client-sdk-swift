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

struct ByteStreamInfoTests {
    @Test func protocolTypeConversion() {
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
        #expect(header.streamID == info.id)
        #expect(header.mimeType == info.mimeType)
        #expect(header.topic == info.topic)
        #expect(header.timestamp == Int64(info.timestamp.timeIntervalSince1970 * TimeInterval(1000)))
        #expect(header.totalLength == UInt64(info.totalLength ?? -1))
        #expect(header.attributes == info.attributes)
        #expect(header.encryptionType.rawValue == info.encryptionType.rawValue)
        #expect(header.byteHeader.name == info.name)

        let newInfo = ByteStreamInfo(header, header.byteHeader, .gcm)
        #expect(newInfo.id == info.id)
        #expect(newInfo.mimeType == info.mimeType)
        #expect(newInfo.topic == info.topic)
        #expect(newInfo.timestamp == info.timestamp)
        #expect(newInfo.totalLength == info.totalLength)
        #expect(newInfo.attributes == info.attributes)
        #expect(newInfo.encryptionType == info.encryptionType)
        #expect(newInfo.name == info.name)
    }
}
