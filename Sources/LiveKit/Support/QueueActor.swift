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

actor QueueActor<T: Sendable>: Loggable {
    typealias OnProcess = @Sendable (T) async -> Void

    // MARK: - Public

    enum State: Sendable {
        case resumed
        case suspended
    }

    private(set) var state: State = .suspended

    var count: Int { queue.count }

    // MARK: - Private

    private var queue = [T]()
    private let onProcess: OnProcess

    init(onProcess: @escaping OnProcess) {
        self.onProcess = onProcess
    }

    /// Mark as `.suspended`.
    func suspend() {
        state = .suspended
    }

    /// Only process if `.resumed` state, otherwise enqueue.
    func processIfResumed(_ value: T, or condition: Bool = false, elseEnqueue: Bool = true) async {
        await process(value, if: state == .resumed || condition, elseEnqueue: elseEnqueue)
    }

    /// Only process if `condition` is true, otherwise enqueue.
    func process(_ value: T, if condition: Bool, elseEnqueue: Bool = true) async {
        if condition {
            await onProcess(value)
        } else if elseEnqueue {
            queue.append(value)
        }
    }

    func clear() {
        if !queue.isEmpty {
            log("Clearing queue which is not empty", .warning)
        }

        queue.removeAll()
        state = .suspended
    }

    /// Mark as `.resumed` and process each element with an async `block`.
    func resume() async {
        state = .resumed
        if queue.isEmpty { return }
        for element in queue {
            // Check cancellation before processing next block...
            // try Task.checkCancellation()
            await onProcess(element)
        }
        queue.removeAll()
    }
}
