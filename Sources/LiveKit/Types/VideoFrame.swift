/*
 * Copyright 2023 LiveKit
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

public class VideoFrame: NSObject {

    let dimensions: Dimensions

    // TODO: Implement

    public init(dimensions: Dimensions) {
        self.dimensions = dimensions
    }
}

internal extension RTCVideoFrame {

    func toLKType() -> VideoFrame {
        // TODO: Implement
        VideoFrame(dimensions: Dimensions(width: width, height: height))
    }
}

internal extension VideoFrame {

    func toRTCType() -> RTCVideoFrame {
        // TODO: Implement
        let pb = RTCCVPixelBuffer()
        return RTCVideoFrame(buffer: pb, rotation: ._0, timeStampNs: 0)
    }
}
