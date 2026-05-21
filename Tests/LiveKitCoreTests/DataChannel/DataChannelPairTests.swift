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
        do {
            try await pair.openCompleter.wait(timeout: 0.1)
            Issue.record("Expected openCompleter to time out")
        } catch let error as LiveKitError {
            #expect(error.type == .timedOut)
        } catch {
            Issue.record("Expected LiveKitError, got \(error)")
        }
    }

    @Test func resetFailsParkedSendsWithProvidedError() async throws {
        let pair = DataChannelPair()

        // No channels are set, so the send enqueues and parks.
        let sendTask = Task {
            try await pair.send(userPacket: Livekit_UserPacket(), kind: .reliable)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        pair.reset(throwing: LiveKitError(.invalidState, message: "custom"))
        await expectLiveKitError(.invalidState, from: sendTask)
    }

    @Test func resetWithNilErrorFailsParkedSendsAsCancelled() async throws {
        let pair = DataChannelPair()

        let sendTask = Task {
            try await pair.send(userPacket: Livekit_UserPacket(), kind: .reliable)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        pair.reset(throwing: nil)
        await expectLiveKitError(.cancelled, from: sendTask)
    }

    @Test func openCompleterWaitHonorsTaskCancellation() async {
        let pair = DataChannelPair()
        let waitTask = Task { try await pair.openCompleter.wait() }
        await waitForRegistration(of: pair.openCompleter)

        waitTask.cancel()
        await expectLiveKitError(.cancelled, from: waitTask)
    }
}

private func waitForRegistration(of completer: AsyncCompleter<some Any>) async {
    while completer.waiterCount == 0 {
        await Task.yield()
    }
}

private func expectLiveKitError(_ expected: LiveKitErrorType, from task: Task<some Sendable, Error>) async {
    do {
        _ = try await task.value
        Issue.record("Expected LiveKitError(.\(expected)) to be thrown")
    } catch let error as LiveKitError {
        #expect(error.type == expected)
    } catch {
        Issue.record("Expected LiveKitError, got \(error)")
    }
}
