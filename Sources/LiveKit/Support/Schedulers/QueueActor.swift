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

actor QueueActor<T: Sendable>: Loggable {
    typealias OnProcess = @Sendable (T) async -> Void

    // MARK: - Public

    enum State {
        case resumed
        case suspended
    }

    private(set) var state: State = .suspended

    var count: Int { queue.count }

    // MARK: - Private

    private var queue = [T]()
    private var isDraining = false
    private let onProcess: OnProcess

    init(onProcess: @escaping OnProcess) {
        self.onProcess = onProcess
    }

    /// Mark as `.suspended`.
    func suspend() {
        state = .suspended
    }

    /// Only process if `.resumed` state, otherwise enqueue.
    ///
    /// While `resume()` is still draining, a value that may be enqueued joins the tail of the
    /// queue instead of running ahead of the older ones; a value that may not (`elseEnqueue ==
    /// false`) is processed at once, as it is whenever the state is `.resumed`. `condition`
    /// bypasses the queue either way, for values that must never wait.
    func processIfResumed(_ value: T, or condition: Bool = false, elseEnqueue: Bool = true) async {
        let isResumed = state == .resumed && !(isDraining && elseEnqueue)
        await process(value, if: isResumed || condition, elseEnqueue: elseEnqueue)
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

    /// Mark as `.resumed` and process the queued elements in arrival order, one at a time.
    ///
    /// The loop re-reads the live queue, so it also processes what arrives while it runs (see
    /// `processIfResumed`), and it stops when `clear()` or `suspend()` changes the state. A
    /// `resume()` that finds a drain already running returns after marking the state: that drain
    /// will reach every queued element, and a second loop would put two elements in flight.
    func resume() async {
        state = .resumed
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while state == .resumed, !queue.isEmpty {
            let element = queue.removeFirst()
            await onProcess(element)
        }
    }
}
