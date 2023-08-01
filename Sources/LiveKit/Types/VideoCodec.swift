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
public enum VideoCodec: Int, StringRepresentable, CustomStringConvertible, CaseIterable, Loggable {

    case none
    case h264
    case vp8
    case vp9
    case av1

    public var rawStringValue: String? {
        switch self {
        case .h264: return "h264"
        case .vp8: return "vp8"
        case .vp9: return "vp9"
        case .av1: return "av1"
        default: return nil
        }
    }

    public init?(rawStringValue: String) {
        switch rawStringValue.lowercased() {
        case "h264": self = .h264
        case "vp8": self = .vp8
        case "vp9": self = .vp9
        case "av1": self = .av1
        default: self = .none
        }
    }
}

extension VideoCodec {

    public var description: String {
        "VideoCodec(\(rawStringValue ?? "nil"))"
    }
}
