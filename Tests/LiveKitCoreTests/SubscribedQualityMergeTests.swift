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
import LiveKitNanopb
import Testing

struct SubscribedQualityMergeTests {
    private func quality(_ quality: Livekit_VideoQuality, _ enabled: Bool) -> Livekit_SubscribedQuality {
        Livekit_SubscribedQuality.with {
            $0.quality = quality
            $0.enabled = enabled
        }
    }

    @Test func replacesMatchingQualityInPlace() {
        let cached = [quality(.low, true), quality(.medium, true), quality(.high, true)]

        let merged = cached.merged(with: [quality(.medium, false)])

        #expect(merged.count == 3)
        #expect(merged.map(\.quality) == [.low, .medium, .high])
        #expect(merged[1].enabled == false)
    }

    @Test func appendsQualityNotYetKnown() {
        let cached = [quality(.low, true)]

        let merged = cached.merged(with: [quality(.high, false)])

        #expect(merged.map(\.quality) == [.low, .high])
        #expect(merged[1].enabled == false)
    }

    @Test func leavesUnmentionedQualitiesUntouched() {
        // An update carries only what changed, so replacing the list instead of merging would
        // forget that .low was paused — the bug this helper exists to prevent.
        let cached = [quality(.low, false), quality(.medium, false)]

        let merged = cached.merged(with: [quality(.high, true)])

        #expect(merged.count == 3)
        #expect(merged.filter { !$0.enabled }.map(\.quality) == [.low, .medium])
    }

    @Test func preservesOrderWhenReplacingAndAppending() {
        let cached = [quality(.high, true), quality(.low, true)]

        let merged = cached.merged(with: [quality(.low, false), quality(.medium, false)])

        #expect(merged.map(\.quality) == [.high, .low, .medium])
    }

    @Test func ownsMergedEntries() {
        // Views pin the whole decoded message they came from, and the result is kept on the track.
        let update = Livekit_SubscribedCodec.with {
            $0.codec = "vp8"
            $0.qualities = [quality(.low, false)]
        }

        let merged = [Livekit_SubscribedQuality]().merged(with: update.qualities)

        let allEntriesAreOwned = merged.allSatisfy(\._ownsItsStorage)
        #expect(allEntriesAreOwned)
    }
}
