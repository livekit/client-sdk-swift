/*
 * Copyright 2024 LiveKit
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
public protocol VideoTrack where Self: Track {
    @objc(addVideoRenderer:)
    func add(videoRenderer: VideoRenderer)

    @objc(removeVideoRenderer:)
    func remove(videoRenderer: VideoRenderer)
}

// Directly add/remove renderers for better performance
protocol VideoTrack_Internal where Self: Track {
    func add(rtcVideoRenderer: LKRTCVideoRenderer)

    func remove(rtcVideoRenderer: LKRTCVideoRenderer)
}

extension VideoTrack {
    // Update a single SubscribedCodec
    func _set(subscribedCodec: Livekit_SubscribedCodec) throws -> Bool {
        // ...
        let videoCodec = try VideoCodec.from(id: subscribedCodec.codec)

        // Check if main sender is sending the codec...
        if let rtpSender = _state.rtpSender, videoCodec == _state.videoCodec {
            rtpSender._set(subscribedQualities: subscribedCodec.qualities)
            return true
        }

        // Find simulcast sender for codec...
        if let rtpSender = _state.rtpSenderForCodec[videoCodec] {
            rtpSender._set(subscribedQualities: subscribedCodec.qualities)
            return true
        }

        return false
    }

    // Update an array of SubscribedCodecs
    func _set(subscribedCodecs: [Livekit_SubscribedCodec]) throws -> [Livekit_SubscribedCodec] {
        // ...
        var missingCodecs: [Livekit_SubscribedCodec] = []

        for subscribedCodec in subscribedCodecs {
            let didUpdate = try _set(subscribedCodec: subscribedCodec)
            if !didUpdate {
                log("Sender for codec \(subscribedCodec.codec) not found", .info)
                missingCodecs.append(subscribedCodec)
            }
        }

        return missingCodecs
    }
}
