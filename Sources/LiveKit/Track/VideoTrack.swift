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

extension VideoTrack {

    public func add(videoView: VideoView) {

        // must always be called on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        guard let videoTrack = self.mediaTrack as? RTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        videoTrack.add(videoView)
        videoViews.add(videoView)
    }

    public func remove(videoView: VideoView) {

        // must always be called on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        videoViews.remove(videoView)

        guard let videoTrack = self.mediaTrack as? RTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        videoTrack.remove(videoView)
    }
}
