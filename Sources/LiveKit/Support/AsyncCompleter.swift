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

/// Manages a map of AsyncCompleters
actor CompleterMapActor<T> {
    // MARK: - Public

    public nonisolated let label: String

    // MARK: - Private

    private let _defaultTimeOut: DispatchTimeInterval
    private var _completerMap = [String: AsyncCompleter<T>]()

    public init(label: String, defaultTimeOut: DispatchTimeInterval) {
        self.label = label
        _defaultTimeOut = defaultTimeOut
    }

    public func completer(for key: String) -> AsyncCompleter<T> {
        // Return completer if already exists...
        if let element = _completerMap[key] {
            return element
        }

        let newCompleter = AsyncCompleter<T>(label: label, defaultTimeOut: _defaultTimeOut)
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

    private let _defaultTimeOut: DispatchTimeInterval
    private let _queue = DispatchQueue(label: "LiveKitSDK.AsyncCompleter", qos: .background)
    // Internal states
    private var _continuations: [UUID: UnsafeContinuation<T, any Error>] = [:]
    private var _timeOutBlocks: [UUID: DispatchWorkItem] = [:]

    private var _returningValue: T?
    private var _throwingError: Error?

    private let _lock = UnfairLock()

    public init(label: String, defaultTimeOut: DispatchTimeInterval) {
        self.label = label
        _defaultTimeOut = defaultTimeOut
    }

    deinit {
        reset()
    }

    // Must be called while locked
    private func _cancelTimer() {
        // Make sure time-out blocked doesn't fire
        for timeOutBlock in _timeOutBlocks.values {
            timeOutBlock.cancel()
        }
        _timeOutBlocks.removeAll()
    }

    public func reset() {
        _lock.sync {
            _cancelTimer()

            let count = _continuations.count
            if count > 0 {
                for continuation in _continuations.values {
                    continuation.resume(throwing: LiveKitError(.cancelled))
                }
                _continuations.removeAll()
                log("\(label) cancelled \(count) completers")
            }

            _returningValue = nil
            _throwingError = nil
        }
    }

    public func resume(returning value: T) {
        log("\(label)")
        _lock.sync {
            _cancelTimer()

            let count = _continuations.count
            if count > 0 {
                for continuation in _continuations.values {
                    continuation.resume(returning: value)
                }
                _continuations.removeAll()
                log("\(label) resumed value for \(count) completers")
            }

            _returningValue = value
        }
    }

    public func resume(throwing error: Error) {
        log("\(label)")
        _lock.sync {
            _cancelTimer()

            let count = _continuations.count
            if count > 0 {
                for continuation in _continuations.values {
                    continuation.resume(throwing: error)
                }
                _continuations.removeAll()
                log("\(label) resumed error for \(count) completers")
            }

            _throwingError = error
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

        // Create ids for continuation & timeOutBlock
        let continuationId = UUID()
        let timeOutBlockId = UUID()

        log("\(label) continuation \(continuationId) waiting...")

        // Create a cancel-aware timed continuation
        return try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { continuation in

                // Create time-out block
                let timeOutBlock = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.log("\(self.label) timedOut")
                    self._lock.sync {
                        continuation.resume(throwing: LiveKitError(.timedOut, message: "\(self.label) AsyncCompleter timed out"))
                        self._continuations.removeValue(forKey: continuationId)
                        if let _timeOutBlock = self._timeOutBlocks[timeOutBlockId] {
                            _timeOutBlock.cancel()
                            self._timeOutBlocks.removeValue(forKey: timeOutBlockId)
                        }
                    }
                }

                _lock.sync {
                    // Schedule time-out block
                    _queue.asyncAfter(deadline: .now() + _defaultTimeOut, execute: timeOutBlock)
                    // Store reference to continuation
                    _continuations[continuationId] = continuation
                    // Store reference to time-out block
                    _timeOutBlocks[timeOutBlockId] = timeOutBlock
                }
            }
        } onCancel: {
            // Cancel only this completer when Task gets cancelled
            _lock.sync {
                if let continuation = _continuations[continuationId] {
                    continuation.resume(throwing: LiveKitError(.cancelled))
                    _continuations.removeValue(forKey: continuationId)
                }

                if let timeOutBlock = _timeOutBlocks[timeOutBlockId] {
                    timeOutBlock.cancel()
                    _timeOutBlocks.removeValue(forKey: timeOutBlockId)
                }
            }
        }
    }
}
