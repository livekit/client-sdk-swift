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

/// Manages a map of AsyncCompleters
actor CompleterMapActor<T: Sendable> {
    // MARK: - Public

    nonisolated let label: String

    // MARK: - Private

    private let _defaultTimeout: TimeInterval
    private var _completerMap = [String: AsyncCompleter<T>]()

    init(label: String, defaultTimeout: TimeInterval) {
        self.label = label
        _defaultTimeout = defaultTimeout
    }

    func completer(for key: String) -> AsyncCompleter<T> {
        // Return completer if already exists...
        if let element = _completerMap[key] {
            return element
        }

        let newCompleter = AsyncCompleter<T>(label: label, defaultTimeout: _defaultTimeout)
        _completerMap[key] = newCompleter
        return newCompleter
    }

    func resume(returning value: T, for key: String) {
        let completer = completer(for: key)
        completer.resume(returning: value)
    }

    func resume(throwing error: any Error, for key: String) {
        let completer = completer(for: key)
        completer.resume(throwing: error)
    }

    func reset() {
        // Reset call completers...
        for (_, value) in _completerMap {
            value.reset()
        }
        // Clear all completers...
        _completerMap.removeAll()
    }
}

final class AsyncCompleter<T: Sendable>: @unchecked Sendable, Loggable {
    //
    struct WaitEntry {
        let continuation: UnsafeContinuation<T, Error>
        let timeoutBlock: DispatchWorkItem

        func cancel() {
            continuation.resume(throwing: LiveKitError(.cancelled))
            timeoutBlock.cancel()
        }

        func timeout() {
            continuation.resume(throwing: LiveKitError(.timedOut))
            timeoutBlock.cancel()
        }

        func resume(with result: Result<T, Error>) {
            continuation.resume(with: result)
            timeoutBlock.cancel()
        }
    }

    let label: String

    private let _timerQueue = DispatchQueue(label: "LiveKitSDK.AsyncCompleter", qos: .background)

    // Internal states
    private var _defaultTimeout: DispatchTimeInterval
    private var _entries: [UUID: WaitEntry] = [:]
    private var _result: Result<T, Error>?

    private let _lock: some Lock = createLock()

    init(label: String, defaultTimeout: TimeInterval) {
        self.label = label
        _defaultTimeout = defaultTimeout.toDispatchTimeInterval
    }

    deinit {
        reset()
    }

    func set(defaultTimeout: TimeInterval) {
        _lock.sync {
            _defaultTimeout = defaultTimeout.toDispatchTimeInterval
        }
    }

    func reset() {
        _lock.sync {
            for entry in _entries.values {
                entry.cancel()
            }
            _entries.removeAll()
            _result = nil
        }
    }

    func resume(with result: Result<T, Error>) {
        _lock.sync {
            for entry in _entries.values {
                entry.resume(with: result)
            }
            _entries.removeAll()
            _result = result
        }
    }

    func resume(returning value: T) {
        log("\(label)", .trace)
        resume(with: .success(value))
    }

    func resume(throwing error: Error) {
        log("\(label)", .error)
        resume(with: .failure(error))
    }

    func wait(timeout: TimeInterval? = nil) async throws -> T {
        // Read value
        if let result = _lock.sync({ _result }) {
            // Already resolved...
            if case let .success(value) = result {
                // resume(returning:) already called
                return value
            } else if case let .failure(error) = result {
                // resume(throwing:) already called
                log("\(label) throwing existing error")
                throw error
            }
        }

        // Create ids for continuation & timeoutBlock
        let entryId = UUID()

        // Create a cancel-aware timed continuation
        return try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { continuation in
                // Create time-out block
                let timeoutBlock = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    log("\(label) id: \(entryId) timed out")
                    _lock.sync {
                        if let entry = self._entries[entryId] {
                            entry.timeout()
                        }
                        self._entries.removeValue(forKey: entryId)
                    }
                }

                _lock.sync {
                    // Schedule time-out block
                    let computedTimeout = (timeout?.toDispatchTimeInterval ?? _defaultTimeout)
                    _timerQueue.asyncAfter(deadline: .now() + computedTimeout, execute: timeoutBlock)
                    // Store entry
                    _entries[entryId] = WaitEntry(continuation: continuation, timeoutBlock: timeoutBlock)

                    log("\(label) id: \(entryId) waiting for \(computedTimeout)")
                }
            }
        } onCancel: {
            // Cancel only this completer when Task gets cancelled
            _lock.sync {
                if let entry = self._entries[entryId] {
                    entry.cancel()
                }
                self._entries.removeValue(forKey: entryId)
            }
        }
    }
}
