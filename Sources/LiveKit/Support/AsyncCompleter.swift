/*
 * Copyright 2023 LiveKit
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

/// Manages a map of AsyncCompleters
actor CompleterMapActor<T> {
    // MARK: - Public

    public nonisolated let label: String

    // MARK: - Private

    private let _timeOut: DispatchTimeInterval
    private var _completerMap = [String: AsyncCompleter<T>]()

    public init(label: String, timeOut: DispatchTimeInterval) {
        self.label = label
        _timeOut = timeOut
    }

    public func completer(for key: String) -> AsyncCompleter<T> {
        // Return completer if already exists...
        if let element = _completerMap[key] {
            return element
        }

        let newCompleter = AsyncCompleter<T>(label: label, timeOut: _timeOut)
        _completerMap[key] = newCompleter
        return newCompleter
    }

    public func resume(returning value: T, for key: String) {
        if let element = _completerMap[key] {
            element.resume(returning: value)
        }
    }

    public func reset() {
        // Reset call completers...
        for (_, value) in _completerMap {
            value.reset()
        }
        // Clear all completers...
        _completerMap.removeAll()
    }
}

class AsyncCompleter<T>: Loggable {
    public let label: String

    private let _timeOut: DispatchTimeInterval
    private let _queue = DispatchQueue(label: "LiveKitSDK.AsyncCompleter", qos: .background)
    // Internal states
    private var _continuation: CheckedContinuation<T, any Error>?
    private var _timeOutBlock: DispatchWorkItem?

    private var _returningValue: T?
    private var _throwingError: Error?

    private let _lock = UnfairLock()

    public init(label: String, timeOut: DispatchTimeInterval) {
        self.label = label
        _timeOut = timeOut
    }

    deinit {
        reset()
    }

    private func _cancelTimer() {
        // Make sure time-out blocked doesn't fire
        _timeOutBlock?.cancel()
        _timeOutBlock = nil
    }

    public func reset() {
        _lock.sync {
            _cancelTimer()
            if let continuation = _continuation {
                log("\(label) Cancelled")
                continuation.resume(throwing: LiveKitError(.cancelled))
            }
            _continuation = nil
            _returningValue = nil
            _throwingError = nil
        }
    }

    public func resume(returning value: T) {
        log("\(label)")
        _lock.sync {
            _cancelTimer()
            _returningValue = value
            _continuation?.resume(returning: value)
            _continuation = nil
        }
    }

    public func resume(throwing error: Error) {
        log("\(label)")
        _lock.sync {
            _cancelTimer()
            _throwingError = error
            _continuation?.resume(throwing: error)
            _continuation = nil
        }
    }

    public func wait() async throws -> T {
        // resume(returning:) already called
        if let returningValue = _lock.sync({ _returningValue }) {
            log("\(label) returning value...")
            return returningValue
        }

        // resume(throwing:) already called
        if let throwingError = _lock.sync({ _throwingError }) {
            log("\(label) throwing error...")
            throw throwingError
        }

        log("\(label) waiting...")

        // Cancel any previous waits
        reset()

        // Create a cancel-aware timed continuation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Create time-out block
                let timeOutBlock = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.log("\(self.label) timedOut")
                    self._lock.sync {
                        self._continuation?.resume(throwing: LiveKitError(.timedOut))
                        self._continuation = nil
                    }
                    self.reset()
                }
                _lock.sync {
                    // Schedule time-out block
                    _queue.asyncAfter(deadline: .now() + _timeOut, execute: timeOutBlock)
                    // Store reference to continuation
                    _continuation = continuation
                    // Store reference to time-out block
                    _timeOutBlock = timeOutBlock
                }
            }
        } onCancel: {
            // Cancel completer when Task gets cancelled
            reset()
        }
    }
}
