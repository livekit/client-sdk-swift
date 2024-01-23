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

@_implementationOnly import WebRTC

@objc
public class LocalVideoTrack: Track, LocalTrack, VideoTrack {
    @objc
    public internal(set) var capturer: VideoCapturer

    var videoSource: LKRTCVideoSource

    init(name: String,
         source: Track.Source,
         capturer: VideoCapturer,
         videoSource: LKRTCVideoSource,
         reportStatistics: Bool)
    {
        let rtcTrack = Engine.createVideoTrack(source: videoSource)
        rtcTrack.isEnabled = true

        self.capturer = capturer
        self.videoSource = videoSource

        super.init(name: name,
                   kind: .video,
                   source: source,
                   track: rtcTrack,
                   reportStatistics: reportStatistics)
    }

    public func mute() async throws {
        try await super._mute()
    }

    public func unmute() async throws {
        try await super._unmute()
    }

    // MARK: - Internal

    override func startCapture() async throws {
        try await capturer.startCapture()
    }

    override func stopCapture() async throws {
        try await capturer.stopCapture()
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

public extension LocalVideoTrack {
    var publishOptions: PublishOptions? { super._publishOptions }

    var publishState: Track.PublishState { super._publishState }
}

public extension LocalVideoTrack {
    /// Clone with same ``VideoCapturer``.
    func clone() -> LocalVideoTrack {
        LocalVideoTrack(name: name,
                        source: source,
                        capturer: capturer,
                        videoSource: videoSource,
                        reportStatistics: _state.reportStatistics)
    }
}
