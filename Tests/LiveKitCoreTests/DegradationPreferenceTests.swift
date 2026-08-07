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

struct DegradationPreferenceTests {
    @Test func autoResolvesBySource() {
        // smoother video for real-time communication
        #expect(DegradationPreference.auto.resolve(for: .camera) == .maintainFramerate)
        // clarity is critical for reading text/UI
        #expect(DegradationPreference.auto.resolve(for: .screenShareVideo) == .maintainResolution)
    }

    @Test func autoFallsBackToBalancedForOtherSources() {
        // the application declined to declare a motion-vs-detail intent
        #expect(DegradationPreference.auto.resolve(for: .unknown) == .balanced)
    }

    @Test func explicitPreferenceWinsOverSourceDefault() {
        #expect(DegradationPreference.balanced.resolve(for: .camera) == .balanced)
        #expect(DegradationPreference.maintainResolution.resolve(for: .camera) == .maintainResolution)
        #expect(DegradationPreference.maintainFramerate.resolve(for: .screenShareVideo) == .maintainFramerate)
        #expect(DegradationPreference.maintainFramerateAndResolution.resolve(for: .unknown) == .maintainFramerateAndResolution)
    }

    @Test func defaultVideoPublishOptionsUseAuto() {
        #expect(VideoPublishOptions().degradationPreference == .auto)
    }
}
