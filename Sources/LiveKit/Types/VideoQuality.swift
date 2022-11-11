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

internal enum VideoQuality {
    case low
    case medium
    case high
}

internal extension VideoQuality {

    static let rids = ["q", "h", "f"]
}

internal extension VideoQuality {

    private static let toPBTypeMap: [VideoQuality: Livekit_VideoQuality] = [
        .low: .low,
        .medium: .medium,
        .high: .high
    ]

    func toPBType() -> Livekit_VideoQuality {
        return Self.toPBTypeMap[self] ?? .low
    }
}

internal extension Livekit_VideoQuality {

    private static let toSDKTypeMap: [Livekit_VideoQuality: VideoQuality] = [
        .low: .low,
        .medium: .medium,
        .high: .high
    ]

    func toSDKType() -> VideoQuality {
        return Self.toSDKTypeMap[self] ?? .low
    }

    static func from(rid: String?) -> Livekit_VideoQuality {
        switch rid {
        case "h": return Livekit_VideoQuality.medium
        case "q": return Livekit_VideoQuality.low
        default: return Livekit_VideoQuality.high
        }
    }
}
