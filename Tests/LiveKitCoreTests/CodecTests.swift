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

struct CodecTests {
    // VideoCodec is a class (not Sendable), so use mimeType strings for parameterization.
    @Test(arguments: [
        ("video/vp8", "vp8"),
        ("video/vp9", "vp9"),
        ("video/h264", "h264"),
        ("video/h265", "h265"),
        ("video/av1", "av1"),
    ])
    func parseCodec(mimeType: String, expectedName: String) {
        let codec = VideoCodec.from(mimeType: mimeType)
        #expect(codec?.name == expectedName)
    }

    @Test(arguments: ["VP8", "VP9", "AV1", "H264", "H265"])
    func supportedCodec(name: String) {
        let encoderCodecs = RTC.encoderFactory.supportedCodecs()
        let decoderCodecs = RTC.decoderFactory.supportedCodecs()

        #expect(encoderCodecs.contains(where: { $0.name == name }), "\(name) not found in encoder codecs")
        #expect(decoderCodecs.contains(where: { $0.name == name }), "\(name) not found in decoder codecs")
    }
}
