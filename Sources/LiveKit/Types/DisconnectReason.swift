/*
 * Copyright 2022 LiveKit
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
import WebRTC

public enum DisconnectReason {
    case user // User initiated
    case networkError(_ error: Error)
    // New cases
    case unknown
    case duplicateIdentity
    case serverShutdown
    case participantRemoved
    case roomDeleted
    case stateMismatch
    case joinFailure
}

extension Livekit_DisconnectReason {

    func toLKType() -> DisconnectReason {
        switch self {
        case .clientInitiated: return .user
        case .duplicateIdentity: return .duplicateIdentity
        case .serverShutdown: return .serverShutdown
        case .participantRemoved: return .participantRemoved
        case .roomDeleted: return .roomDeleted
        case .stateMismatch: return .stateMismatch
        case .joinFailure: return .joinFailure
        default: return .unknown
        }
    }
}

extension DisconnectReason: Equatable {

    public static func == (lhs: DisconnectReason, rhs: DisconnectReason) -> Bool {
        lhs.isEqual(to: rhs)
    }

    public func isEqual(to rhs: DisconnectReason, includingAssociatedValues: Bool = true) -> Bool {
        switch (self, rhs) {
        case (.user, .user): return true
        case (.networkError, .networkError): return true
        // New cases
        case (.unknown, .unknown): return true
        case (.duplicateIdentity, .duplicateIdentity): return true
        case (.serverShutdown, .serverShutdown): return true
        case (.participantRemoved, .participantRemoved): return true
        case (.roomDeleted, .roomDeleted): return true
        case (.stateMismatch, .stateMismatch): return true
        case (.joinFailure, .joinFailure): return true
        default: return false
        }
    }

    var networkError: Error? {
        if case .networkError(let error) = self {
            return error
        }

        return nil
    }

    @available(*, deprecated, renamed: "networkError")
    var error: Error? { networkError }
}
