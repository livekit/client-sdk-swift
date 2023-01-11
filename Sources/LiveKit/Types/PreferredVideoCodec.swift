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

@objc
public enum PreferredVideoCodec: Int {
    case auto = 0
    case h264 = 1
    case vp8 = 2
    case av1 = 3

    func toCodecCapability() -> RTCRtpCodecCapability? {
        guard self != .auto else { return nil }
        let codecCapability = RTCRtpCodecCapability()
        codecCapability.kind = .video
        codecCapability.name = String(describing: self)
        codecCapability.clockRate = NSNumber(value: 90000) // required
        return codecCapability
    }
}

@objc
public enum PreferredBackupVideoCodec: Int {
    case auto = 0
    case h264 = 1
    case vp8 = 2

}

// MARK: - CustomStringConvertible

extension PreferredVideoCodec: CustomStringConvertible {

    public var description: String {
        switch self {
        case .auto: return "auto"
        case .h264: return "H264"
        case .vp8: return "VP8"
        case .av1: return "AV1"
        }
    }
}
