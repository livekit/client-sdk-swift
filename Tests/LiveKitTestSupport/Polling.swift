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

/// Thrown by ``poll(timeout:interval:for:until:)`` so a missed condition stops the test at the
/// first stall instead of letting later assertions cascade against state that never arrived.
public struct PollTimeoutError: Error, CustomStringConvertible {
    public let description: String
}

/// Polls `condition` until it holds, throwing ``PollTimeoutError`` after `timeout`.
///
/// The shared shape for "wait until the thing under test has acted" — use this instead of a
/// file-private copy (several test files grew their own variants with drifting timeouts) and
/// instead of a fixed `Task.sleep`, which flakes when the cooperative pool is busy and silently
/// passes negative assertions.
public func poll(
    timeout: TimeInterval = 2,
    interval: TimeInterval = 0.005,
    for description: String,
    until condition: @escaping @Sendable () -> Bool,
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    guard condition() else {
        throw PollTimeoutError(description: "timed out waiting for: \(description)")
    }
}
