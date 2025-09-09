/*
 * Copyright 2025 LiveKit
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

let msecPerSec = 1000

// merge a ClosedRange
func merge<T>(range range1: ClosedRange<T>, with range2: ClosedRange<T>) -> ClosedRange<T> where T: Comparable {
    min(range1.lowerBound, range2.lowerBound) ... max(range1.upperBound, range2.upperBound)
}

// throws a timeout if the operation takes longer than the given timeout
func withThrowingTimeout<T: Sendable>(timeout: TimeInterval,
                                      operation: @Sendable @escaping () async throws -> T) async throws -> T
{
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw LiveKitError(.timedOut)
        }

        let result = try await group.next()

        group.cancelAll()

        guard let result else {
            // This should never happen since we know we added tasks
            throw LiveKitError(.invalidState)
        }

        return result
    }
}
