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
public enum PreferredVideoCodec: Int, VideoCodec {

    case auto
    case h264
    case vp8
    case av1

    var rawStringValue: String? {
        switch self {
        case .h264: return "h264"
        case .vp8: return "vp8"
        case .av1: return "av1"
        default: return nil
        }
    }
}

@objc
public enum PreferredBackupVideoCodec: Int, VideoCodec {

    case off
    case h264
    case vp8

    var rawStringValue: String? {
        switch self {
        case .h264: return "h264"
        case .vp8: return "vp8"
        default: return nil
        }
    }
}

protocol VideoCodec: StringRepresentable, CustomStringConvertible {

}

extension VideoCodec {

    func toCodecCapability() -> RTCRtpCodecCapability? {
        guard let codecName = rawStringValue else { return nil }
        let codecCapability = RTCRtpCodecCapability()
        codecCapability.kind = .video
        codecCapability.name = codecName.uppercased() // must be upper case
        codecCapability.clockRate = NSNumber(value: 90000) // required
        return codecCapability
    }
}

extension VideoCodec {

    public var description: String {
        "VideoCodec(\(rawStringValue ?? "nil"))"
    }
}
