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

import Combine
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

struct DarwinNotificationCenterTests {
    @Test func publisher() async {
        let name = DarwinNotification.broadcastStarted

        await confirmation("Receive from both subscribers", expectedCount: 2) { confirm in
            var cancellable = Set<AnyCancellable>()
            DarwinNotificationCenter.shared
                .publisher(for: name)
                .sink {
                    #expect($0 == name)
                    confirm()
                }
                .store(in: &cancellable)
            DarwinNotificationCenter.shared
                .publisher(for: name)
                .sink {
                    #expect($0 == name)
                    confirm()
                }
                .store(in: &cancellable)

            DarwinNotificationCenter.shared.postNotification(name)

            // Allow time for delivery
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
