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

@Suite(.tags(.media))
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

    @Test(
        "H264 advertises both ConstrainedHigh and ConstrainedBaseline profiles",
        .bug("https://github.com/livekit/client-sdk-swift/issues/1002", "iOS 26 VideoToolbox SW fallback"),
        .bug("https://github.com/livekit/client-sdk-swift/issues/144", "iOS unable to publish 1080p simulcast"),
        .bug("https://github.com/livekit/client-sdk-swift/pull/147", "PR that pinned profile-level-id=42e032 across all platforms"),
        arguments: ["encoder", "decoder"]
    )
    func h264ProfileLevelIds(factory: String) {
        let codecs = factory == "encoder"
            ? RTC.encoderFactory.supportedCodecs()
            : RTC.decoderFactory.supportedCodecs()
        let h264 = codecs.filter { $0.name == "H264" }
        let profiles = h264.compactMap { $0.parameters["profile-level-id"] }

        // Guard against the SDK collapsing the upstream pair (ConstrainedHigh + ConstrainedBaseline)
        // into a single profile. The simulcast encoder factory wraps primary+fallback so the raw
        // count can be doubled — dedup by profile-level-id before asserting.
        #expect(
            Set(profiles).count == 2,
            "[\(factory)] expected 2 distinct H264 profile-level-ids, got: \(profiles)"
        )
        #expect(
            profiles.contains { $0.hasPrefix("640c") },
            "[\(factory)] ConstrainedHigh (640c…) missing from H264 codecs: \(profiles)"
        )
        #expect(
            profiles.contains { $0.hasPrefix("42e0") },
            "[\(factory)] ConstrainedBaseline (42e0…) missing from H264 codecs: \(profiles)"
        )

        for codec in h264 {
            let pli = codec.parameters["profile-level-id"] ?? "?"
            #expect(
                codec.parameters["level-asymmetry-allowed"] == "1",
                "[\(factory)] H264 \(pli): level-asymmetry-allowed != 1"
            )
            #expect(
                codec.parameters["packetization-mode"] == "1",
                "[\(factory)] H264 \(pli): packetization-mode != 1"
            )

            // Guard against PR #147 regression: level must be at least 3.1 (0x1f), the
            // upstream fallback. Anything lower breaks resolutions ≥ 1280×720@30 (issue #144).
            // The byte is the H264 level_idc in decimal, hex-encoded (e.g. 34 = L5.2, 1f = L3.1).
            let levelHex = pli.suffix(2)
            let level = UInt8(levelHex, radix: 16) ?? 0
            #expect(
                level >= 0x1F,
                "[\(factory)] H264 \(pli): level \(String(format: "%02x", level)) below 1f (L3.1) floor"
            )
        }
    }

    @Test("H264 sender capabilities expose both ConstrainedHigh and ConstrainedBaseline")
    func h264SenderCapabilitiesExposeBothProfiles() {
        let plis = Set(RTC.videoSenderCapabilities.codecs
            .filter { $0.name == "H264" }
            .compactMap { $0.parameters["profile-level-id"] })
        #expect(plis.count == 2, "expected ConstrainedHigh + ConstrainedBaseline in videoSenderCapabilities, got: \(plis)")
    }
}
