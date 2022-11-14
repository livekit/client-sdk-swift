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

extension TrackSettings: CustomStringConvertible {

    public var description: String {
        "TrackSettings(enabled: \(enabled), dimensions: \(dimensions), videoQuality: \(videoQuality))"
    }
}

extension Livekit_VideoLayer: CustomStringConvertible {

    public var description: String {
        "VideoLayer(quality: \(quality), dimensions: \(width)x\(height), bitrate: \(bitrate))"
    }
}

extension TrackPublication {

    public override var description: String {
        "\(String(describing: type(of: self)))(sid: \(sid), kind: \(kind), source: \(source))"
    }
}

extension Livekit_AddTrackRequest: CustomStringConvertible {

    public var description: String {
        "AddTrackRequest(cid: \(cid), name: \(name), type: \(type), source: \(source), width: \(width), height: \(height), muted: \(muted))"
    }
}

extension Livekit_TrackInfo: CustomStringConvertible {

    public var description: String {
        "TrackInfo(sid: \(sid), name: \(name), type: \(type), source: \(source), width: \(width), height: \(height), muted: \(muted))"
    }
}

extension Livekit_SubscribedQuality: CustomStringConvertible {

    public var description: String {
        "SubscribedQuality(quality: \(quality), enabled: \(enabled))"
    }
}

// MARK: - NSObject

extension Room {

    public override var description: String {
        "Room(sid: \(sid ?? "nil"), name: \(name ?? "nil"), serverVersion: \(serverVersion ?? "nil"), serverRegion: \(serverRegion ?? "nil"))"
    }
}

extension Participant {

    public override var description: String {
        "\(String(describing: type(of: self)))(sid: \(sid))"
    }
}

extension Track {

    public override var description: String {
        "\(String(describing: type(of: self)))(sid: \(sid ?? "nil"), name: \(name), source: \(source))"
    }
}

extension RTCRtpEncodingParameters {

    public override var description: String {
        "RTCRtpEncodingParameters(rid: \(rid ?? "nil"), "
            + "active: \(isActive), "
            + "scaleResolutionDownBy: \(String(describing: scaleResolutionDownBy)), "
            + "maxBitrateBps: \(maxBitrateBps == nil ? "nil" : String(describing: maxBitrateBps)), "
            + "maxFramerate: \(maxFramerate == nil ? "nil" : String(describing: maxFramerate)))"
    }
}

extension RTCDataChannelState: CustomStringConvertible {

    public var description: String {
        switch self {
        case .connecting: return ".connecting"
        case .open: return ".open"
        case .closing: return ".closing"
        case .closed: return ".closed"
        @unknown default: return ".unknown"
        }
    }
}
