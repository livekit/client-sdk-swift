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

#if os(iOS) || os(visionOS) || os(tvOS)

import Foundation
@testable import LiveKit
import Testing

struct AudioSessionAutomaticActivationTests {
    /// Activation stays with the SDK unless an app opts out, so existing apps are unaffected.
    @Test func enabledByDefault() {
        let observer = AudioSessionEngineObserver()
        #expect(observer.isAutomaticActivationEnabled)
        #expect(observer._state.isAutomaticActivationEnabled)
    }
}

#endif
