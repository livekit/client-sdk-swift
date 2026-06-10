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

#if compiler(>=6.4) && !COCOAPODS
internal import LKObjCHelpers
#endif

extension AVAudioNode {
    /// The underlying audio unit's `maximumFramesToRender`.
    ///
    /// The macOS 27 SDK restricts `auAudioUnit` to macOS 13.0; below that it's reached through
    /// ``LKObjCHelpers``, which keeps the property's original Objective-C availability (macOS 10.13).
    /// See #1035.
    var maximumFramesToRender: AUAudioFrameCount {
        get {
            #if compiler(>=6.4)
            if #available(macOS 13.0, *) {
                return auAudioUnit.maximumFramesToRender
            } else {
                return LKObjCHelpers.maximumFramesToRender(for: self)
            }
            #else
            return auAudioUnit.maximumFramesToRender
            #endif
        }
        set {
            #if compiler(>=6.4)
            if #available(macOS 13.0, *) {
                auAudioUnit.maximumFramesToRender = newValue
            } else {
                LKObjCHelpers.setMaximumFramesToRender(newValue, for: self)
            }
            #else
            auAudioUnit.maximumFramesToRender = newValue
            #endif
        }
    }
}
