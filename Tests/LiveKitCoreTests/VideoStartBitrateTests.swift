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
import LiveKitWebRTC
import Testing

@Suite(.tags(.media))
struct VideoStartBitrateTests {
    // MARK: - Per-track hint

    @Test(arguments: [
        (2_300_000, false, 1000), // camera, capped
        (800_000, false, 720),
        (334_000, false, 301),
        (5_000_000, true, 4500), // screen share, uncapped
    ])
    func hintsNinetyPercentOfTheTarget(targetBps: Int, isScreenShare: Bool, expectedKbps: Int) {
        #expect(Transport.startBitrateKbps(targetBps: targetBps, isScreenShare: isScreenShare) == expectedKbps)
    }

    /// A hint under libwebrtc's own 300 kbps default would start the estimator lower than no
    /// hint at all. A 330 kbps target would hint 297 kbps, so it gets none.
    @Test func givesNoHintBelowLibwebrtcsDefault() {
        #expect(Transport.startBitrateKbps(targetBps: 330_000, isScreenShare: false) == nil)
        #expect(Transport.startBitrateKbps(targetBps: 330_000, isScreenShare: true) == nil)
        #expect(Transport.startBitrateKbps(targetBps: 300_000, isScreenShare: false) == nil)
    }

    @Test func sumsTheActiveEncodings() {
        func encoding(_ bps: Int, active: Bool = true) -> LKRTCRtpEncodingParameters {
            let encoding = LKRTCRtpEncodingParameters()
            encoding.maxBitrateBps = NSNumber(value: bps)
            encoding.isActive = active
            return encoding
        }

        // 150 + 500 + 1700 kbps of simulcast layers is a 2350 kbps target, capped for camera.
        let simulcast = [encoding(150_000), encoding(500_000), encoding(1_700_000)]
        #expect(Transport.startBitrateKbps(for: simulcast, isScreenShare: false) == 1000)
        #expect(Transport.startBitrateKbps(for: simulcast, isScreenShare: true) == 2115)

        let lowestOnly = [encoding(150_000), encoding(500_000, active: false), encoding(1_700_000, active: false)]
        #expect(Transport.startBitrateKbps(for: lowestOnly, isScreenShare: false) == nil)

        #expect(Transport.startBitrateKbps(for: [LKRTCRtpEncodingParameters()], isScreenShare: false) == nil)
    }
}
