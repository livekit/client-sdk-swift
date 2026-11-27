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
import LiveKitFFI

/// Foundation HTTP and WebSocket adapters for the Rust host-transport artifact.
public enum LiveKitTransport {
    /// Attempts to register both native defaults once per process, before networking.
    ///
    /// LiveKit v2 calls this automatically. Direct FFI callers should call it at startup.
    /// Choose one startup owner: Rust retains each client independently, first registration
    /// wins, and later registrations silently do nothing. This call cannot establish that
    /// these defaults won either slot. Custom owners must register both clients first.
    public static func initialize() {
        _ = registration
    }

    private static let registration: Void = {
        setHttpClient(c: NativeHTTPClient())
        setWsClient(c: NativeWebSocketClient())
    }()
}

func transportError(_ error: Error) -> TransportError {
    if let error = error as? TransportError { return error }
    if error is CancellationError { return .Closed }
    let native = error as NSError
    guard native.domain == NSURLErrorDomain else { return .Other(String(describing: error)) }
    switch native.code {
    case NSURLErrorTimedOut: return .Timeout
    case NSURLErrorCancelled: return .Closed
    default: return .Connection(String(describing: error))
    }
}

func requestURL(_ value: String, schemes: [String]) throws -> URL {
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
          schemes.contains(scheme), let host = url.host, !host.isEmpty
    else { throw TransportError.Connection("Invalid transport URL") }
    return url
}

// Foundation callbacks and cancellation may finish before the continuation is installed.
// The lock protects all mutable state; resumption happens outside it. Remove this bridge
// when the minimum OS supplies cancellation-safe native async APIs for every operation.
final class Completion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func resolve(_ result: Result<Value, Error>) {
        let continuation = lock.withLock {
            guard self.result == nil else { return nil as CheckedContinuation<Value, Error>? }
            self.result = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withLock {
                if self.result == nil { self.continuation = continuation }
                return self.result
            }
            if let result { continuation.resume(with: result) }
        }
    }
}
