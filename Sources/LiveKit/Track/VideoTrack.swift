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

internal import LiveKitWebRTC

@objc
public protocol VideoTrackProtocol: AnyObject, Sendable {
    @objc(addVideoRenderer:)
    func add(videoRenderer: VideoRenderer)

    @objc(removeVideoRenderer:)
    func remove(videoRenderer: VideoRenderer)
}

public typealias VideoTrack = Track & VideoTrackProtocol

// Directly add/remove renderers for better performance
protocol VideoTrackInternal where Self: Track {
    func add(rtcVideoRenderer: LKRTCVideoRenderer)

    func remove(rtcVideoRenderer: LKRTCVideoRenderer)
}

extension VideoTrackProtocol where Self: Track {
    // Update a single SubscribedCodec
    @RTC
    func _set(subscribedCodec: Livekit_SubscribedCodec) throws -> Bool {
        guard let videoCodec = VideoCodec.from(name: subscribedCodec.codec) else { return false }

        // Check if main sender is sending the codec...
        if let rtpSender = _state.rtpSender, videoCodec == _state.videoCodec {
            rtpSender.raw._set(subscribedQualities: _merge(subscribedCodec.qualities, for: videoCodec))
            return true
        }

        // Find simulcast sender for codec...
        if let rtpSender = _state.rtpSenderForCodec[videoCodec] {
            rtpSender.raw._set(subscribedQualities: _merge(subscribedCodec.qualities, for: videoCodec))
            return true
        }

        return false
    }

    /// Accumulates `qualities` into the codec's cache and returns the whole known state for it.
    ///
    /// Senders are fed the accumulated list rather than the incoming one, because a re-apply after
    /// renegotiation can only replay what is cached — the two must agree or the layers flip.
    private func _merge(_ qualities: [Livekit_SubscribedQuality], for videoCodec: VideoCodec) -> [Livekit_SubscribedQuality] {
        let cached = _state.read { $0.subscribedQualitiesForCodec[videoCodec] ?? [] }
        let merged = cached.merged(with: qualities)
        // A re-apply writes back what is already stored, and every mutate notifies the track's
        // delegates synchronously — on the blocking @RTC queue, for each codec, on each answer.
        guard !merged.sameState(as: cached) else { return merged }
        _state.mutate { $0.subscribedQualitiesForCodec[videoCodec] = merged }
        return merged
    }

    // Update an array of SubscribedCodecs
    @RTC
    func _set(subscribedCodecs: [Livekit_SubscribedCodec]) throws -> [Livekit_SubscribedCodec] {
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

public extension Track {
    /// The aspect ratio of the video track or 1 if the dimensions are not available.
    var aspectRatio: CGFloat {
        guard let dimensions else { return 1 }
        return CGFloat(dimensions.width) / CGFloat(dimensions.height)
    }
}
