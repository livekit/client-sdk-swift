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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

@objc
public enum E2EEState: Int, Sendable {
    case new
    case ok
    case key_ratcheted
    case missing_key
    case encryption_failed
    case decryption_failed
    case internal_error
}

public extension E2EEState {
    func toString() -> String {
        switch self {
        case .new: return "new"
        case .ok: return "ok"
        case .key_ratcheted: return "key_ratcheted"
        case .missing_key: return "missing_key"
        case .encryption_failed: return "encryption_failed"
        case .decryption_failed: return "decryption_failed"
        case .internal_error: return "internal_error"
        default: return "internal_error"
        }
    }
}

extension FrameCryptionState {
    func toLKType() -> E2EEState {
        switch self {
        case .new: return .new
        case .ok: return .ok
        case .keyRatcheted: return .key_ratcheted
        case .missingKey: return .missing_key
        case .encryptionFailed: return .encryption_failed
        case .decryptionFailed: return .decryption_failed
        case .internalError: return .internal_error
        default: return .internal_error
        }
    }
}
