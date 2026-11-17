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

    // Internal barrier for testing cancellation after a subscriber has actually registered.
    private let onSubscribe: (@Sendable (Int) -> Void)?
    private let read: @Sendable () async -> StreamProgress?
    private var latest: Update?
    private var pending = false
    private var finished = false
    private var subscribers: [UUID: CheckedContinuation<Update?, Error>] = [:]

    init(onSubscribe: (@Sendable (Int) -> Void)? = nil, read: @escaping @Sendable () async -> StreamProgress?) {
        self.onSubscribe = onSubscribe
        self.read = read
    }

    func next(after version: Int) async throws -> Update? {
        try Task.checkCancellation()
        if let latest, latest.version > version { return latest }
        if finished { return nil }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                subscribers[id] = continuation
                onSubscribe?(version)
                if !pending {
                    pending = true
                    // The shared native wait must not inherit an observer's task-local resources.
                    Task.detached(priority: Task.currentPriority) { [read] in
                        await self.publish(read())
                    }
                }
            }
        } onCancel: {
            // This actor hop ends immediately after detaching the subscriber; it never waits on core.
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func publish(_ value: StreamProgress?) {
        if let value {
            latest = Update(version: (latest?.version ?? 0) + 1, progress: value)
        } else {
            finished = true
        }
        pending = false
        let waiting = subscribers.values
        subscribers.removeAll()
        for subscriber in waiting {
            subscriber.resume(returning: value == nil ? nil : latest)
        }
    }
}
