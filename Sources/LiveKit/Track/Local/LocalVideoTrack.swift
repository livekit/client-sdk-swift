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
import ReplayKit

public class LocalVideoTrack: LocalTrack, VideoTrack {

    public internal(set) var capturer: VideoCapturer
    public internal(set) var videoSource: RTCVideoSource

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

    @discardableResult
    public override func start() -> Promise<Bool> {
        super.start().then(on: .sdk) { didStart in
            self.capturer.startCapture().then(on: .sdk) { _ in
                // wait for dimensions to resolve
                self.capturer.dimensionsCompleter.wait(on: .sdk, .defaultCaptureStart)
            }.then(on: .sdk) { _ in
                didStart
            }
        }
    }

    @discardableResult
    public override func stop() -> Promise<Bool> {
        super.stop().then(on: .sdk) { didStop in
            self.capturer.stopCapture().then(on: .sdk) { _ in didStop }
        }
    }
}

extension RTCRtpEncodingParameters {
    open override var description: String {
        return "RTCRtpEncodingParameters(rid: \(rid ?? "nil"), "
            + "active: \(isActive), "
            + "scaleResolutionDownBy: \(String(describing: scaleResolutionDownBy)), "
            + "maxBitrateBps: \(maxBitrateBps == nil ? "nil" : String(describing: maxBitrateBps)), "
            + "maxFramerate: \(maxFramerate == nil ? "nil" : String(describing: maxFramerate)))"
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
