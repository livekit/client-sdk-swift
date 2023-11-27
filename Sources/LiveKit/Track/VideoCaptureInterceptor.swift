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

public typealias CaptureFunc = (_ capture: RTCVideoFrame) -> Void
public typealias InterceptFunc = (_ frame: RTCVideoFrame, _ capture: @escaping CaptureFunc) -> Void

public class VideoCaptureInterceptor: NSObject, RTCVideoCapturerDelegate, Loggable {

    let output = Engine.createVideoSource(forScreenShare: true)
    let interceptFunc: InterceptFunc

    public init(_ interceptFunc: @escaping InterceptFunc) {
        self.interceptFunc = interceptFunc
        super.init()
        log("VideoCaptureInterceptor.init()")
    }

    deinit {
        log("VideoCaptureInterceptor.deinit()")
    }

    public func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {

        // create capture func to pass to intercept func
        let captureFunc = { [weak self, weak capturer] (frame: RTCVideoFrame) -> Void in
            guard let self = self,
                  let capturer = capturer else {
                return
            }

            // TODO: provide access to adaptOutputFormat
            // self.output.adaptOutputFormat(toWidth: 100, height: 100, fps: 15)
            self.output.capturer(capturer, didCapture: frame)
        }

        // call intercept func with frame & capture func
        interceptFunc(frame, captureFunc)
    }
}
