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

/// Shares one native wait across observers. The task owns only this relay and the core reader;
/// releasing the public reader closes the core and wakes it. A cancelled observer cannot consume
/// an update without caching it for the next observer.
actor StreamProgressRelay {
    struct Update: Sendable {
        let version: Int
        let progress: StreamProgress
    }

    private let read: @Sendable () async -> StreamProgress?
    private var latest: Update?
    private var pending: Task<Update?, Never>?
    private var finished = false

    init(read: @escaping @Sendable () async -> StreamProgress?) {
        self.read = read
    }

    func next(after version: Int) async throws -> Update? {
        try Task.checkCancellation()
        if let latest, latest.version > version { return latest }
        if finished { return nil }
        let task: Task<Update?, Never>
        if let pending {
            task = pending
        } else {
            task = Task {
                let value = await read()
                if let value {
                    latest = Update(version: (latest?.version ?? 0) + 1, progress: value)
                } else {
                    finished = true
                }
                pending = nil
                return value == nil ? nil : latest
            }
            pending = task
        }
        // Abandon only this observer's wait. The shared task publishes its result even if every
        // observer cancels, and a replacement can replay the last update after native EOF.
        return try await abandoningOnCancel { await task.value }
    }
}
