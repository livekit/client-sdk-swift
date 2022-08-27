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

import WebRTC

public protocol VideoTrack: Track {

}

@objc public protocol VideoRenderer: RTCVideoRenderer {
    /// Whether this ``VideoRenderer`` should be considered visible or not for AdaptiveStream.
    /// This will be invoked on the .main thread.
    var adaptiveStreamIsEnabled: Bool { get }
    /// The size used for AdaptiveStream computation. Return .zero if size is unknown yet.
    /// This will be invoked on the .main thread.
    var adaptiveStreamSize: CGSize { get }
}

extension VideoTrack {

    public func add(videoRenderer: VideoRenderer) {

        guard let videoTrack = self.mediaTrack as? RTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        // must always be called on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        videoRenderers.add(videoRenderer)
        videoTrack.add(videoRenderer)
    }

    public func remove(videoRenderer: VideoRenderer) {

        guard let videoTrack = self.mediaTrack as? RTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        // must always be called on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        videoRenderers.remove(videoRenderer)
        videoTrack.remove(videoRenderer)
    }
}
