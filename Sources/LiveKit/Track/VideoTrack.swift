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

        DispatchQueue.main.async { [weak self] in

            guard let self = self, let videoTrack = self.mediaTrack as? RTCVideoTrack else { return }

            guard !self.videoViews.allObjects.contains(videoView) else {
                self.log("already attached", .warning)
                return
            }

            while let otherVideoView = self.videoViews.allObjects.first(where: { $0 != videoView }) {
                videoTrack.remove(otherVideoView)
                self.videoViews.remove(otherVideoView)
            }

            assert(self.videoViews.allObjects.count <= 1, "multiple VideoViews attached")

            videoTrack.add(videoView)
            self.videoViews.add(videoView)
        }
    }

    public func remove(videoView: VideoView) {

        DispatchQueue.main.async { [weak self] in

            guard let self = self else { return }

            self.videoViews.remove(videoView)

            guard let videoTrack = self.mediaTrack as? RTCVideoTrack else { return }

            videoTrack.remove(videoView)
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
