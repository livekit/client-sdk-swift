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

import CoreGraphics
@testable import LiveKit
import Testing

struct AdaptiveStreamPixelDensityTests {
    @Test func autoUsesScreenScale() {
        #expect(VideoView.AdaptiveStreamPixelDensity.auto.resolve(screenScale: 1) == 1)
        #expect(VideoView.AdaptiveStreamPixelDensity.auto.resolve(screenScale: 2) == 2)
        #expect(VideoView.AdaptiveStreamPixelDensity.auto.resolve(screenScale: 2.75) == 2.75)
    }

    @Test func fixedIgnoresScreenScale() {
        #expect(VideoView.AdaptiveStreamPixelDensity.fixed(1).resolve(screenScale: 3) == 1)
        #expect(VideoView.AdaptiveStreamPixelDensity.fixed(1.5).resolve(screenScale: 1) == 1.5)
    }

    @Test func capsAtMaxDensity() {
        #expect(VideoView.AdaptiveStreamPixelDensity.auto.resolve(screenScale: 4) == 3)
        #expect(VideoView.AdaptiveStreamPixelDensity.fixed(5).resolve(screenScale: 1) == 3)
        #expect(VideoView.AdaptiveStreamPixelDensity.maxDensity == 3)
    }

    @Test func invalidDensityFallsBackToOne() {
        #expect(VideoView.AdaptiveStreamPixelDensity.auto.resolve(screenScale: 0) == 1)
        #expect(VideoView.AdaptiveStreamPixelDensity.auto.resolve(screenScale: -2) == 1)
        #expect(VideoView.AdaptiveStreamPixelDensity.auto.resolve(screenScale: .nan) == 1)
        #expect(VideoView.AdaptiveStreamPixelDensity.fixed(0).resolve(screenScale: 2) == 1)
        #expect(VideoView.AdaptiveStreamPixelDensity.fixed(-1).resolve(screenScale: 2) == 1)
        #expect(VideoView.AdaptiveStreamPixelDensity.fixed(.nan).resolve(screenScale: 2) == 1)
    }
}
