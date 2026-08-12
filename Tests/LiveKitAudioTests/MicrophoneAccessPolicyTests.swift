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

import AVFoundation
@testable import LiveKit
import Testing

@Suite(.tags(.audio)) struct MicrophoneAccessPolicyTests {
    @Test func authorizedProceeds() {
        #expect(LiveKitSDK.microphoneAccessAction(for: .authorized) == .proceed)
    }

    @Test func notDeterminedRequests() {
        #expect(LiveKitSDK.microphoneAccessAction(for: .notDetermined) == .request)
    }

    // No prompt can change these, so they must not trigger one.
    @Test func deniedAndRestrictedNeverPrompt() {
        #expect(LiveKitSDK.microphoneAccessAction(for: .denied) == .deny)
        #expect(LiveKitSDK.microphoneAccessAction(for: .restricted) == .deny)
    }
}
