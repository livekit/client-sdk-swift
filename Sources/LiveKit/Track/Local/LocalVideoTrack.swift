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
import WebRTC
import Promises

@objc
public class LocalVideoTrack: Track, LocalTrack, VideoTrack {

    @objc
    public internal(set) var capturer: VideoCapturer

    @objc
    public internal(set) var videoSource: RTCVideoSource

    internal var simulcastCodecs = [VideoCodec: SimulcastTrackInfo]()

    internal var codec: VideoCodec?

    internal init(name: String,
                  source: Track.Source,
                  capturer: VideoCapturer,
                  videoSource: RTCVideoSource) {

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
        super.start().then(on: queue) { didStart -> Promise<Bool> in
            // Start simulcast tracks (if any)...
            let promises = self.simulcastCodecs.values.map { $0.track.start() }
            return all(on: self.queue, promises).then(on: self.queue) { _ in didStart }
        }.then(on: queue) { didStart in
            self.capturer.startCapture().then(on: self.queue) { _ in didStart }
        }
    }

    override public func stop() -> Promise<Bool> {
        super.stop().then(on: queue) { didStop -> Promise<Bool> in
            // Stop simulcast tracks (if any)...
            let promises = self.simulcastCodecs.values.map { $0.track.stop() }
            return all(on: self.queue, promises).then(on: self.queue) { _ in didStop }
        }.then(on: queue) { didStop in
            self.capturer.stopCapture().then(on: self.queue) { _ in didStop }
        }
    }
}

extension LocalVideoTrack {

    public func add(videoRenderer: VideoRenderer) {
        super._add(videoRenderer: videoRenderer)
    }

    public func remove(videoRenderer: VideoRenderer) {
        super._remove(videoRenderer: videoRenderer)
    }
}

// MARK: - Deprecated methods

extension LocalVideoTrack {

    @available(*, deprecated, message: "Use CameraCapturer's methods instead to switch cameras")
    public func restartTrack(options: CameraCaptureOptions = CameraCaptureOptions()) -> Promise<Bool> {
        guard let capturer = capturer as? CameraCapturer else {
            return Promise(TrackError.state(message: "Must be an CameraCapturer"))
        }
        capturer.options = options
        return capturer.restartCapture()
    }
}

extension LocalVideoTrack {

    public var publishOptions: PublishOptions? { super._publishOptions }

    public var publishState: Track.PublishState { super._publishState }
}

// MARK: - Simulcast Codecs

extension LocalVideoTrack {

    internal struct SimulcastTrackInfo {
        let codec: VideoCodec
        let track: LocalVideoTrack
        var sender: RTCRtpSender?
        var encodings: [RTCRtpEncodingParameters]?
    }

    internal func addSimulcastTrack(for codec: VideoCodec,
                                    encodings: [RTCRtpEncodingParameters]?) throws -> SimulcastTrackInfo {

        log("codec: \(codec), encodings: \(encodings == nil ? "nil" : String(describing: encodings!))")

        if simulcastCodecs[codec] != nil {
            log("Codec \(codec) is already added", .warning)
            throw EngineError.state(message: "Codec \(codec) is already added")
        }

        let info = SimulcastTrackInfo(codec: codec,
                                      track: clone(),
                                      sender: nil,
                                      encodings: nil)
        simulcastCodecs[codec] = info
        return info
    }

    internal func set(simulcastSender sender: RTCRtpSender, for codec: VideoCodec, publisher: Transport) {

        log("codec: \(codec), sender: \(sender)")

        // find by codec
        guard var info = simulcastCodecs[codec] else {
            assert(false, "Codec not found")
            return
        }

        // set the sender
        info.sender = sender
    }
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
