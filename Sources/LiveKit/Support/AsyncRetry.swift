/*
 * Copyright 2024 LiveKit
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

extension Task where Failure == Error {
    static func retrying(
        priority: TaskPriority? = nil,
        maxRetryCount: Int = 3,
        retryDelay: TimeInterval = 1,
        @_implicitSelfCapture operation: @escaping (_ totalAttempts: Int, _ currentAttempt: Int) async throws -> Success
    ) -> Task {
        assert(maxRetryCount >= 1, "Value must be larger than 1")

        return Task(priority: priority) {
            for currentCount in 0 ..< (maxRetryCount - 1) {
                do {
                    return try await operation(maxRetryCount, currentCount + 1)
                } catch {
                    let oneSecond = TimeInterval(1_000_000_000)
                    let delay = UInt64(oneSecond * retryDelay)

                    // print("Retry waiting for \(retryDelay) seconds...")
                    try await Task<Never, Never>.sleep(nanoseconds: delay)

                    continue
                }
            }

            try Task<Never, Never>.checkCancellation()
            return try await operation(maxRetryCount, maxRetryCount)
        }
    }
}
