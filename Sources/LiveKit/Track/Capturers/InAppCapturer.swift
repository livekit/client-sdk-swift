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

#if canImport(ReplayKit)
import ReplayKit
#endif

@available(macOS 11.0, iOS 11.0, *)
public class InAppScreenCapturer: VideoCapturer {

    private let capturer = Engine.createVideoCapturer()
    private var options: ScreenShareCaptureOptions

    init(delegate: RTCVideoCapturerDelegate, options: ScreenShareCaptureOptions) {
        self.options = options
        super.init(delegate: delegate)
    }

    public override func startCapture() -> Promise<Bool> {

        super.startCapture().then(on: queue) {didStart -> Promise<Bool> in

            guard didStart else {
                // already started
                return Promise(false)
            }

            return Promise<Bool>(on: self.queue) { resolve, fail in

                // TODO: force pixel format kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                RPScreenRecorder.shared().startCapture { sampleBuffer, type, _ in
                    if type == .video {

                        self.delegate?.capturer(self.capturer, didCapture: sampleBuffer) { sourceDimensions in

                            let targetDimensions = sourceDimensions
                                .aspectFit(size: self.options.dimensions.max)
                                .toEncodeSafeDimensions()

                            defer { self.dimensions = targetDimensions }

                            guard let videoSource = self.delegate as? RTCVideoSource else { return }
                            // self.log("adaptOutputFormat to: \(targetDimensions) fps: \(self.options.fps)")
                            videoSource.adaptOutputFormat(toWidth: targetDimensions.width,
                                                          height: targetDimensions.height,
                                                          fps: Int32(self.options.fps))
                        }
                    }
                } completionHandler: { error in
                    if let error = error {
                        fail(error)
                        return
                    }
                    resolve(true)
                }
            }
        }
    }

    public override func stopCapture() -> Promise<Bool> {

        super.stopCapture().then(on: queue) { didStop -> Promise<Bool> in

            guard didStop else {
                // already stopped
                return Promise(false)
            }

            return Promise<Bool>(on: self.queue) { resolve, fail in

                RPScreenRecorder.shared().stopCapture { error in
                    if let error = error {
                        fail(error)
                        return
                    }
                    resolve(true)
                }

            }
        }
    }
}

extension LocalVideoTrack {
    /// Creates a track that captures in-app screen only (due to limitation of ReplayKit)
    @available(macOS 11.0, iOS 11.0, *)
    public static func createInAppScreenShareTrack(name: String = Track.screenShareVideoName,
                                                   options: ScreenShareCaptureOptions = ScreenShareCaptureOptions()) -> LocalVideoTrack {
        let videoSource = Engine.createVideoSource(forScreenShare: true)
        let capturer = InAppScreenCapturer(delegate: videoSource, options: options)
        return LocalVideoTrack(
            name: name,
            source: .screenShareVideo,
            capturer: capturer,
            videoSource: videoSource
        )
    }
}
