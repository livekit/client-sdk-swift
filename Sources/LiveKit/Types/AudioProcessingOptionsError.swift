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

/// An error thrown when audio processing options cannot be applied.
public struct AudioProcessingOptionsError: LocalizedError, Sendable {
    /// The machine-readable reason the request failed.
    public enum Code: Sendable {
        /// The receiving track is not in a state that accepts processing options.
        case invalidState
        /// The requested per-effect combination is not supported.
        case invalidCombination
        /// A platform implementation was required but is unavailable.
        case platformUnavailable
        /// The engine failed to apply the options.
        case applyFailed
    }

    /// The machine-readable reason the request failed.
    public let code: Code

    /// Details supplied by the audio processing implementation, if available.
    public let message: String

    /// A localized description containing the failure code and available details.
    public var errorDescription: String? {
        let reason = message.isEmpty ? "\(code)" : "\(code): \(message)"
        return "Failed to set audio processing options: \(reason)"
    }
}
