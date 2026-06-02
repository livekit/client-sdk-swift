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
import Testing

/// Unit-level coverage for the parts of `DataChannelPair` that don't need a
/// real `LKRTCDataChannel`: the pre-flight `openCompleter` semantics and the
/// `.drain` path that fails parked sends after `reset(throwing:)`. Anything
/// that needs real `sendData` dispatch or `bufferedAmount` drains is exercised
/// by `RealiableDataChannelTests` / `EncryptedDataChannelTests` end-to-end.
@Suite(.tags(.dataChannel))
struct DataChannelPairTests {
    @Test func openCompleterTimesOutWhenChannelsNeverArrive() async {
        let pair = DataChannelPair()
        await #expect {
            try await pair.openCompleter.wait(timeout: 0.1)
        } throws: { ($0 as? LiveKitError)?.type == .timedOut }
    }

    @Test func resetFailsParkedSendsWithProvidedError() async throws {
        let pair = DataChannelPair()

        // No channels are set, so the send enqueues and parks.
        let sendTask = Task {
            try await pair.send(userPacket: Livekit_UserPacket(), kind: .reliable)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        pair.reset(throwing: LiveKitError(.invalidState, message: "custom"))
        await #expect {
            try await sendTask.value
        } throws: { ($0 as? LiveKitError)?.type == .invalidState }
    }

    @Test func resetWithNilErrorFailsParkedSendsAsCancelled() async throws {
        let pair = DataChannelPair()

        let sendTask = Task {
            try await pair.send(userPacket: Livekit_UserPacket(), kind: .reliable)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        pair.reset(throwing: nil)
        await #expect {
            try await sendTask.value
        } throws: { ($0 as? LiveKitError)?.type == .cancelled }
    }

    @Test func openCompleterWaitHonorsTaskCancellation() async {
        let pair = DataChannelPair()
        let waitTask = Task { try await pair.openCompleter.wait() }
        await waitForRegistration(of: pair.openCompleter)

        waitTask.cancel()
        await #expect {
            try await waitTask.value
        } throws: { ($0 as? LiveKitError)?.type == .cancelled }
    }
}
