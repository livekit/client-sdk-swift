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
@testable import LiveKitTestSupport
import Testing

/// Setup retries in `TestEnvironment`.
struct TestEnvironmentTests {
    /// A room that reports connected without an identity fails every attempt. A retry that skipped
    /// connected rooms before checking them would turn the first attempt's failure into success.
    @Test func connectedRoomWithoutIdentityFailsEveryAttempt() async {
        let room = Room()
        room._state.onDidMutate = nil
        room._state.mutate { $0.connectionState = .connected }

        await #expect(throws: LiveKitError.self) {
            try await Task.retrying(totalAttempts: 2, retryDelay: 0) { _, _ in
                try await TestEnvironment.connectAttempt([.init(room: room, identity: "unused", url: "ws://127.0.0.1:1", token: "unused")])
            }.value
        }
    }
}
