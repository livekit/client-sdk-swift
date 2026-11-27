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

internal import LiveKitFFI
import Foundation

@objc
public enum VideoQuality: Int, Sendable {
    case low
    case medium
    case high
}

extension VideoQuality {
    static let RIDs = ["q", "h", "f"]
}

// Make convertible between protobuf type.
extension VideoQuality {
    func toNativeType() -> NativeVideoQuality {
        switch self {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }
}
