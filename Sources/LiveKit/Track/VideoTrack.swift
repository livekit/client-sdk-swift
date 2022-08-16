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

public protocol VideoRenderer: RTCVideoRenderer {

}

extension VideoTrack {

    public func add(videoRenderer: VideoRenderer) {

        guard let videoTrack = self.mediaTrack as? RTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        // only if it's a VideoView
        if let videoView = videoRenderer as? VideoView {
            // must always be called on main thread
            assert(Thread.current.isMainThread, "must be called on main thread")
            videoViews.add(videoView)
        }

        videoTrack.add(videoRenderer)
    }

    public func remove(videoRenderer: VideoRenderer) {

        guard let videoTrack = self.mediaTrack as? RTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        // only if it's a VideoView
        if let videoView = videoRenderer as? VideoView {
            // must always be called on main thread
            assert(Thread.current.isMainThread, "must be called on main thread")
            videoViews.remove(videoView)
        }

        videoTrack.remove(videoRenderer)
    }
}
