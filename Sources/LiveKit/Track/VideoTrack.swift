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

internal import LiveKitWebRTC
import Foundation

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

public extension Track {
    /// The aspect ratio of the video track or 1 if the dimensions are not available.
    var aspectRatio: CGFloat {
        guard let dimensions else { return 1 }
        return CGFloat(dimensions.width) / CGFloat(dimensions.height)
    }
}
