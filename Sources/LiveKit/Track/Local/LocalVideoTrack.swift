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
import Promises

@_implementationOnly import WebRTC

@objc
public class LocalVideoTrack: Track, LocalTrack, VideoTrack {

    @objc
    public internal(set) var capturer: VideoCapturer

    internal var videoSource: LKRTCVideoSource

    internal init(name: String,
                  source: Track.Source,
                  capturer: VideoCapturer,
                  videoSource: LKRTCVideoSource) {

        let rtcTrack = Engine.createVideoTrack(source: videoSource)
        rtcTrack.isEnabled = true

        self.capturer = capturer
        self.videoSource = videoSource

        super.init(name: name,
                   kind: .video,
                   source: source,
                   track: rtcTrack)
    }

    override public func start() -> Promise<Bool> {
        super.start().then(on: queue) { didStart in
            self.capturer.startCapture().then(on: self.queue) { _ in didStart }
        }
    }

    override public func stop() -> Promise<Bool> {
        super.stop().then(on: queue) { didStop in
            self.capturer.stopCapture().then(on: self.queue) { _ in didStop }
        }
    }
}

public extension LocalVideoTrack {

    func add(videoRenderer: VideoRenderer) {
        super._add(videoRenderer: videoRenderer)
    }

    func remove(videoRenderer: VideoRenderer) {
        super._remove(videoRenderer: videoRenderer)
    }
}

extension LocalVideoTrack {

    public var publishOptions: PublishOptions? { super._publishOptions }

    public var publishState: Track.PublishState { super._publishState }
}

extension LocalVideoTrack {

    /// Clone with same ``VideoCapturer``.
    public func clone() -> LocalVideoTrack {
        LocalVideoTrack(name: name,
                        source: source,
                        capturer: capturer,
                        videoSource: videoSource)
    }
}
