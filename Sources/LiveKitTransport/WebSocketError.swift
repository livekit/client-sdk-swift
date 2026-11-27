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

/// Socket-local error context; the adapter maps it onto the generated transport taxonomy.
struct WebSocketError: Error {
    enum Kind { case cancelled, timedOut, network, invalidParameter, unknown }
    let type: Kind
    let message: String?
    let internalError: Error?

    init(_ type: Kind, message: String? = nil, internalError: Error? = nil) {
        self.type = type
        self.message = message
        self.internalError = internalError
    }

    static func from(error: Error?) -> WebSocketError? {
        guard let error else { return nil }
        if let error = error as? WebSocketError { return error }
        if error is CancellationError { return WebSocketError(.cancelled) }
        let native = error as NSError
        let socketCodes: Set<Int> = [
            Int(ECONNREFUSED), Int(ECONNRESET), Int(ECONNABORTED), Int(ETIMEDOUT),
            Int(ENETUNREACH), Int(ENETDOWN), Int(EHOSTUNREACH), Int(EPIPE), Int(ENOTCONN),
        ]
        if error is URLError || native.domain == NSURLErrorDomain || native.domain == "kCFErrorDomainCFNetwork"
            || (native.domain == NSPOSIXErrorDomain && socketCodes.contains(native.code))
        {
            return WebSocketError(.network, internalError: error)
        }
        return WebSocketError(.unknown)
    }
}

extension WebSocket {
    static let sdkVersion = "2.20.0"
}
