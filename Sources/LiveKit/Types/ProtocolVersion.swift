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

@objc
public enum ProtocolVersion: Int, Sendable {
    case v8 = 8
    case v9 = 9
    /// Sync stream id
    case v10 = 10
    /// Supports ``ConnectionQuality/lost``
    case v11 = 11
    /// Faster room join (delayed ``Room/sid``)
    case v12 = 12
    /// Regions in leave request, `canReconnect` obsoleted by `action`
    case v13 = 13
    /// Intermediate version preparing for non-error signal responses
    case v14 = 14
    /// Supports move participant and non-error signal responses
    case v15 = 15
    /// Latest version
    case v16 = 16
}

// MARK: - Comparable

extension ProtocolVersion: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - CustomStringConvertible

extension ProtocolVersion: CustomStringConvertible {
    public var description: String {
        String(rawValue)
    }
}
