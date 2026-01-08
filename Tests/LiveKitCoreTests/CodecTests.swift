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

class CodecTests: LKTestCase {
    func testParseCodec() throws {
        // Video codecs
        let vp8 = VideoCodec.from(mimeType: "video/vp8")
        XCTAssert(vp8 == .vp8)

        let vp9 = VideoCodec.from(mimeType: "video/vp9")
        XCTAssert(vp9 == .vp9)

        let h264 = VideoCodec.from(mimeType: "video/h264")
        XCTAssert(h264 == .h264)

        let h265 = VideoCodec.from(mimeType: "video/h265")
        XCTAssert(h265 == .h265)

        let av1 = VideoCodec.from(mimeType: "video/av1")
        XCTAssert(av1 == .av1)
    }

    func testSupportedCodecs() {
        let encoderCodecs = RTC.decoderFactory.supportedCodecs()
        print("encoderCodecs: \(encoderCodecs.map { "\($0.name) - \($0.parameters)" }.joined(separator: ", "))")
        let decoderCodecs = RTC.decoderFactory.supportedCodecs()
        print("decoderCodecs: \(decoderCodecs.map { "\($0.name) - \($0.parameters)" }.joined(separator: ", "))")

        // Check encoder codecs
        XCTAssert(encoderCodecs.contains(where: { $0.name == "VP8" }))
        XCTAssert(encoderCodecs.contains(where: { $0.name == "VP9" }))
        XCTAssert(encoderCodecs.contains(where: { $0.name == "AV1" }))
        XCTAssert(encoderCodecs.contains(where: { $0.name == "H264" }))
        XCTAssert(encoderCodecs.contains(where: { $0.name == "H265" }))

        // Check decoder codecs
        XCTAssert(decoderCodecs.contains(where: { $0.name == "VP8" }))
        XCTAssert(decoderCodecs.contains(where: { $0.name == "VP9" }))
        XCTAssert(decoderCodecs.contains(where: { $0.name == "AV1" }))
        XCTAssert(decoderCodecs.contains(where: { $0.name == "H264" }))
        XCTAssert(encoderCodecs.contains(where: { $0.name == "H265" }))
    }
}
