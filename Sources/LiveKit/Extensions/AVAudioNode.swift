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

import AVFAudio

#if !COCOAPODS
internal import LKObjCHelpers
#endif

extension AVAudioNode {
    /// The underlying audio unit's `maximumFramesToRender`.
    ///
    /// Routed through ``LKObjCHelpers`` so it stays reachable across SDK versions: the macOS 27 SDK's
    /// Swift overlay bumped `auAudioUnit` to macOS 13.0, but the Objective-C property is still macOS 10.13.
    var maximumFramesToRender: AUAudioFrameCount {
        get { LKObjCHelpers.maximumFramesToRender(for: self) }
        set { LKObjCHelpers.setMaximumFramesToRender(newValue, for: self) }
    }
}
