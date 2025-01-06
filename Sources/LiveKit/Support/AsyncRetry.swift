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

extension Task where Failure == Error {
    static func retrying(
        priority: TaskPriority? = nil,
        totalAttempts: Int = 3,
        retryDelay: TimeInterval = 1,
        @_implicitSelfCapture operation: @escaping (_ currentAttempt: Int, _ totalAttempts: Int) async throws -> Success
    ) -> Task {
        Task(priority: priority) {
            for currentAttempt in 1 ..< max(1, totalAttempts) {
                print("[Retry] Attempt \(currentAttempt) of \(totalAttempts), delay: \(retryDelay)")
                do {
                    return try await operation(currentAttempt, totalAttempts)
                } catch {
                    let oneSecond = TimeInterval(1_000_000_000)
                    let delayNS = UInt64(oneSecond * retryDelay)
                    print("[Retry] Waiting for \(retryDelay) seconds...")
                    try await Task<Never, Never>.sleep(nanoseconds: delayNS)
                    continue
                }
            }

            try Task<Never, Never>.checkCancellation()
            return try await operation(totalAttempts, totalAttempts)
        }
    }
}
