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

internal import LiveKitWebRTC

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
        case .new: "new"
        case .ok: "ok"
        case .key_ratcheted: "key_ratcheted"
        case .missing_key: "missing_key"
        case .encryption_failed: "encryption_failed"
        case .decryption_failed: "decryption_failed"
        case .internal_error: "internal_error"
        default: "internal_error"
        }
    }
}

extension LKRTCFrameCryptorState {
    func toLKType() -> E2EEState {
        switch self {
        case .new: .new
        case .ok: .ok
        case .keyRatcheted: .key_ratcheted
        case .missingKey: .missing_key
        case .encryptionFailed: .encryption_failed
        case .decryptionFailed: .decryption_failed
        case .internalError: .internal_error
        default: .internal_error
        }
    }
}
