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
import Promises

internal class AsyncCompleter<T>: Loggable {

    public enum AsyncCompleterError: LiveKitError {
        case timedOut
        case cancelled

        public var description: String {
            switch self {
            case .timedOut: return "Timed out"
            case .cancelled: return "Cancelled"
            }
        }
    }

    public let label: String

    private let _timeOut: DispatchTimeInterval
    private let _queue = DispatchQueue(label: "LiveKitSDK.AsyncCompleter", qos: .background)
    // Internal states
    private var _continuation: CheckedContinuation<T, any Error>?
    private var _timeOutBlock: DispatchWorkItem?

    private var _returningValue: T?
    private var _throwingError: Error?

    public init(label: String, timeOut: DispatchTimeInterval) {
        self.label = label
        self._timeOut = timeOut
    }

    deinit {
        cancel()
    }

    private func _cancelTimer() {
        // Make sure time-out blocked doesn't fire
        _timeOutBlock?.cancel()
        _timeOutBlock = nil
    }

    public func cancel() {
        _cancelTimer()
        _continuation?.resume(throwing: AsyncCompleterError.cancelled)
        _continuation = nil
        _returningValue = nil
        _throwingError = nil
    }

    public func resume(returning value: T) {
        log("\(label)")

        _cancelTimer()

        if let continuation = _continuation {
            continuation.resume(returning: value)
            _continuation = nil
        } else {
            _returningValue = value
        }
    }

    public func resume(throwing error: Error) {
        log("\(label)")

        _cancelTimer()

        if let continuation = _continuation {
            continuation.resume(throwing: error)
            _continuation = nil
        } else {
            _throwingError = error
        }
    }

    public func wait() async throws -> T {
        log("\(label)")

        // resume(returning:) already called
        if let returningValue = _returningValue {
            cancel()
            return returningValue
        }

        // resume(throwing:) already called
        if let throwingError = _throwingError {
            cancel()
            throw throwingError
        }

        // Cancel any previous waits
        cancel()

        // Create a timed continuation
        return try await withCheckedThrowingContinuation { continuation in
            // Store reference to continuation
            _continuation = continuation

            // Create time-out block
            let timeOutBlock = DispatchWorkItem { [weak self] in
                self?._continuation?.resume(throwing: AsyncCompleterError.timedOut)
                self?.cancel()
            }

            // Schedule time-out block
            _queue.asyncAfter(deadline: .now() + _timeOut, execute: timeOutBlock)
            // Store reference to time-out block
            _timeOutBlock = timeOutBlock
        }
    }

    // TODO: Remove helper method when async/await migration completed
    public func waitPromise() -> Promise<T> {
        Promise<T> { resolve, reject in
            Task {
                do {
                    resolve(try await self.wait())
                } catch let error {
                    reject(error)
                }
            }
        }
    }
}
