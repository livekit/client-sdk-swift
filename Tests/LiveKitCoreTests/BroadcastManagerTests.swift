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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

class BroadcastManagerTests: LKTestCase, @unchecked Sendable {
    private var manager: BroadcastManager!

    override func setUp() {
        super.setUp()
        manager = BroadcastManager()
    }

    func testInitialState() {
        XCTAssertFalse(manager.isBroadcasting)
        XCTAssertTrue(manager.shouldPublishTrack)
        XCTAssertNil(manager.delegate)
    }

    func testSetDelegate() {
        let delegate = MockDelegate()
        manager.delegate = delegate
        XCTAssertTrue(manager.delegate === delegate)
    }

    func testSetShouldPublishTrack() {
        manager.shouldPublishTrack = false
        XCTAssertFalse(manager.shouldPublishTrack)
    }

    func testBroadcastStarted() async throws {
        let delegateMethodCalled = expectation(description: "Delegate state change method called")
        let publisherPublished = expectation(description: "Publisher published new state")
        let propertyReflectsState = expectation(description: "Property reflects state change")

        let delegate = MockDelegate()
        manager.delegate = delegate

        delegate.didChangeStateCalled = {
            XCTAssertTrue($0)
            delegateMethodCalled.fulfill()
        }

        var cancellable = Set<AnyCancellable>()
        manager.isBroadcastingPublisher.sink {
            guard $0 else { return } // first call is initial value of false
            publisherPublished.fulfill()
        }
        .store(in: &cancellable)

        // Simulate broadcast start
        DarwinNotificationCenter.shared.postNotification(.broadcastStarted)

        Task {
            try await Task.sleep(nanoseconds: 500_000_000) // wait for delivery
            XCTAssertTrue(manager.isBroadcasting)
            propertyReflectsState.fulfill()
        }

        await fulfillment(
            of: [propertyReflectsState, delegateMethodCalled, publisherPublished],
            timeout: 1.0
        )
    }

    private class MockDelegate: BroadcastManagerDelegate, @unchecked Sendable {
        var didChangeStateCalled: ((Bool) -> Void)?

        func broadcastManager(didChangeState isBroadcasting: Bool) {
            didChangeStateCalled?(isBroadcasting)
        }
    }
}

#endif
