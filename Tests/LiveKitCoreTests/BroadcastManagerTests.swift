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

#if os(iOS)

import Combine
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.tags(.broadcast))
class BroadcastManagerTests: @unchecked Sendable {
    private var manager: BroadcastManager

    init() {
        manager = BroadcastManager()
    }

    @Test func initialState() {
        #expect(!manager.isBroadcasting)
        #expect(manager.shouldPublishTrack)
        #expect(manager.delegate == nil)
    }

    @Test func setDelegate() {
        let delegate = MockDelegate()
        manager.delegate = delegate
        #expect(manager.delegate === delegate)
    }

    @Test func setShouldPublishTrack() {
        manager.shouldPublishTrack = false
        #expect(!manager.shouldPublishTrack)
    }

    @Test func broadcastStarted() async {
        await confirmation("All events", expectedCount: 3) { confirm in
            let delegate = MockDelegate()
            manager.delegate = delegate

            delegate.didChangeStateCalled = {
                #expect($0)
                confirm()
            }

            var cancellable = Set<AnyCancellable>()
            manager.isBroadcastingPublisher.sink {
                guard $0 else { return } // first call is initial value of false
                confirm()
            }
            .store(in: &cancellable)

            // Simulate broadcast start
            DarwinNotificationCenter.shared.postNotification(.broadcastStarted)

            // Wait for delivery
            try? await Task.sleep(nanoseconds: 500_000_000)
            #expect(manager.isBroadcasting)
            confirm()
        }
    }

    private class MockDelegate: BroadcastManagerDelegate, @unchecked Sendable {
        var didChangeStateCalled: ((Bool) -> Void)?

        func broadcastManager(didChangeState isBroadcasting: Bool) {
            didChangeStateCalled?(isBroadcasting)
        }
    }
}

#endif
