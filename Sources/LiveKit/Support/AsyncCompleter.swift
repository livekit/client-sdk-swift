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
    //
    struct WaitEntry {
        let continuation: UnsafeContinuation<T, Error>
        let timeOutBlock: DispatchWorkItem

        func cancel() {
            continuation.resume(throwing: LiveKitError(.cancelled))
            timeOutBlock.cancel()
        }

        func timeOut() {
            continuation.resume(throwing: LiveKitError(.timedOut))
            timeOutBlock.cancel()
        }

        func resume(with result: Result<T, Error>) {
            continuation.resume(with: result)
            timeOutBlock.cancel()
        }
    }

    public let label: String

    private let _defaultTimeOut: DispatchTimeInterval
    private let _timerQueue = DispatchQueue(label: "LiveKitSDK.AsyncCompleter", qos: .background)

    // Internal states
    private var _entries: [UUID: WaitEntry] = [:]
    private var _result: Result<T, Error>?

    private let _lock = UnfairLock()

    public init(label: String, defaultTimeOut: DispatchTimeInterval) {
        self.label = label
        _defaultTimeOut = defaultTimeOut
    }

    deinit {
        reset()
    }

    public func reset() {
        _lock.sync {
            for entry in _entries.values {
                entry.cancel()
            }
            _entries.removeAll()
            _result = nil
        }
    }

    public func resume(with result: Result<T, Error>) {
        _lock.sync {
            for entry in _entries.values {
                entry.resume(with: result)
            }
            _entries.removeAll()
            _result = result
        }
    }

    public func resume(returning value: T) {
        log("\(label)")
        resume(with: .success(value))
    }

    public func resume(throwing error: Error) {
        log("\(label)")
        resume(with: .failure(error))
    }

    public func wait(timeOut: DispatchTimeInterval? = nil) async throws -> T {
        // Read value
        if let result = _lock.sync({ _result }) {
            // Already resolved...
            if case let .success(value) = result {
                // resume(returning:) already called
                log("\(label) returning value...")
                return value
            } else if case let .failure(error) = result {
                // resume(throwing:) already called
                log("\(label) throwing error...")
                throw error
            }
        }

        // Create ids for continuation & timeOutBlock
        let entryId = UUID()

        log("\(label) waiting with id: \(entryId)")

        // Create a cancel-aware timed continuation
        return try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { continuation in

                // Create time-out block
                let timeOutBlock = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.log("Wait \(entryId) timedOut")
                    self._lock.sync {
                        if let entry = self._entries[entryId] {
                            entry.timeOut()
                        }
                        self._entries.removeValue(forKey: entryId)
                    }
                }

                _lock.sync {
                    // Schedule time-out block
                    _timerQueue.asyncAfter(deadline: .now() + (timeOut ?? _defaultTimeOut), execute: timeOutBlock)
                    // Store entry
                    _entries[entryId] = WaitEntry(continuation: continuation, timeOutBlock: timeOutBlock)
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
