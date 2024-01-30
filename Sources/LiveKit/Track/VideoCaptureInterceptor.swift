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

public class VideoCaptureInterceptor: NSObject, Loggable {
    public typealias CaptureFunc = (_ capture: VideoFrame) -> Void
    public typealias InterceptFunc = (_ frame: VideoFrame, _ capture: @escaping CaptureFunc) -> Void

    private class DelegateAdapter: NSObject, LKRTCVideoCapturerDelegate {
        weak var target: VideoCaptureInterceptor?

        init(target: VideoCaptureInterceptor? = nil) {
            self.target = target
        }

        func capturer(_ capturer: LKRTCVideoCapturer, didCapture frame: LKRTCVideoFrame) {
            target?.capturer(capturer, didCapture: frame)
        }
    }

    let output = Engine.createVideoSource(forScreenShare: true)
    let interceptFunc: InterceptFunc

    private lazy var delegateAdapter: DelegateAdapter = .init(target: self)

    public init(_ interceptFunc: @escaping InterceptFunc) {
        self.interceptFunc = interceptFunc
        super.init()
        log("VideoCaptureInterceptor.init()")
    }

    deinit {
        log("VideoCaptureInterceptor.deinit()")
    }

    // MARK: - Internal

    func capturer(_ capturer: LKRTCVideoCapturer, didCapture frame: LKRTCVideoFrame) {
        // create capture func to pass to intercept func
        let captureFunc = { [weak self, weak capturer] (frame: VideoFrame) in
            guard let self,
                  let capturer
            else {
                return
            }

            // TODO: provide access to adaptOutputFormat
            // self.output.adaptOutputFormat(toWidth: 100, height: 100, fps: 15)
            self.output.capturer(capturer, didCapture: frame.toRTCType())
        }

        // call intercept func with frame & capture func
        // interceptFunc(frame.toLKType(), captureFunc)
    }
}
