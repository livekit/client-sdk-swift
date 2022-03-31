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
        guard let videoTrack = mediaTrack as? RTCVideoTrack else { return }

        DispatchQueue.mainSafeSync {

            guard !videoViews.allObjects.contains(videoView) else {
                log("already attached", .warning)
                return
            }

            while let otherVideoView = videoViews.allObjects.first(where: { $0 != videoView }) {
                videoTrack.remove(otherVideoView)
                videoViews.remove(otherVideoView)
            }

            assert(videoViews.allObjects.count <= 1, "multiple VideoViews attached")

            videoTrack.add(videoView)
            videoViews.add(videoView)
        }
    }

    public func remove(videoView: VideoView) {
        guard let videoTrack = mediaTrack as? RTCVideoTrack else { return }

        DispatchQueue.mainSafeSync {
            videoTrack.remove(videoView)
            videoViews.remove(videoView)
        }
    }

    @available(*, deprecated, message: "Use add(videoView:) instead")
    public func add(renderer: VideoView) {
        add(videoView: renderer)
    }

    @available(*, deprecated, message: "Use remove(videoView:) instead")
    public func remove(renderer: VideoView) {
        remove(videoView: renderer)
    }
}
