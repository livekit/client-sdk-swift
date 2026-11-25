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
import Testing

@Suite(.tags(.broadcast))
struct ScreenShareCaptureRoutingTests {
    private let withExtension = ScreenShareCaptureOptions(useBroadcastExtension: true)
    private let withoutExtension = ScreenShareCaptureOptions(useBroadcastExtension: false)

    @Test func explicitShareUsesScreenCaptureKit() {
        #expect(withExtension.prefersScreenCaptureKit(roomDefaults: withExtension, publishesRunningBroadcast: false))
    }

    @Test func broadcastStartPublishesRunningBroadcastInsteadOfPicker() {
        #expect(!withExtension.prefersScreenCaptureKit(roomDefaults: withExtension, publishesRunningBroadcast: true))
    }

    @Test func runningBroadcastIsIgnoredWithoutExtension() {
        #expect(withoutExtension.prefersScreenCaptureKit(roomDefaults: withoutExtension, publishesRunningBroadcast: true))
    }

    @Test func optingOutOfScreenCaptureKitStillApplies() {
        let optedOut = ScreenShareCaptureOptions(useBroadcastExtension: true, useScreenCaptureKit: false)
        #expect(!optedOut.prefersScreenCaptureKit(roomDefaults: optedOut, publishesRunningBroadcast: false))
    }
}
