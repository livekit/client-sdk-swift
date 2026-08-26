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

// MARK: - Token guarantees

/// The two properties ``SendToken`` exists for: settlement is first-wins idempotent (no code path
/// can trap on a double resume), and a token released unsettled fails its submitter instead of
/// stranding it. Chosen over compile-time enforcement via noncopyable writes, which would have
/// required replacing `Deque` with a hand-rolled move-only FIFO.
@Suite(.tags(.dataChannel))
struct SendTokenTests {
    @Test func settleIsFirstWinsIdempotent() async {
        await #expect {
            try await withCheckedThrowingContinuation { continuation in
                let token = SendToken(continuation)
                token.settle(with: .failure(LiveKitError(.invalidState, message: "first")))
                // The exact shape of the fixed double-resume crash: a second settlement attempt
                // on the same waiter. Must be a no-op, not a trap, and must not override.
                token.settle(with: .success(()))
            }
        } throws: { ($0 as? LiveKitError)?.type == .invalidState }
    }

    @Test func releasingAnUnsettledTokenFailsItsSubmitter() async {
        await #expect {
            try await withCheckedThrowingContinuation { continuation in
                var token: SendToken? = SendToken(continuation)
                // A forgotten code path drops the write without settling it; the waiter must get
                // an error rather than hang forever.
                token = nil
                _ = token
            }
        } throws: { ($0 as? LiveKitError)?.type == .cancelled }
    }
}
