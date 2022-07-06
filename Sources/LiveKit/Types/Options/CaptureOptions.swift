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

public protocol CaptureOptions {

}

public protocol VideoCaptureOptions: CaptureOptions {
    var dimensions: Dimensions { get }
    var fps: Int { get }
}

public struct CameraCaptureOptions: VideoCaptureOptions {

    public let position: AVCaptureDevice.Position
    public let preferredFormat: AVCaptureDevice.Format?

    /// preferred dimensions for capturing, the SDK may override with a recommended value.
    public let dimensions: Dimensions

    /// preferred fps to use for capturing, the SDK may override with a recommended value.
    public let fps: Int

    public init(position: AVCaptureDevice.Position = .front,
                preferredFormat: AVCaptureDevice.Format? = nil,
                dimensions: Dimensions = .h720_169,
                fps: Int = 30) {

        self.position = position
        self.preferredFormat = preferredFormat
        self.dimensions = dimensions
        self.fps = fps
    }

    public func copyWith(position: AVCaptureDevice.Position? = nil,
                         preferredFormat: AVCaptureDevice.Format? = nil,
                         dimensions: Dimensions? = nil,
                         fps: Int? = nil) -> CameraCaptureOptions {

        CameraCaptureOptions(position: position ?? self.position,
                             preferredFormat: preferredFormat ?? self.preferredFormat,
                             dimensions: dimensions ?? self.dimensions,
                             fps: fps ?? self.fps)
    }
}

public struct ScreenShareCaptureOptions: VideoCaptureOptions {

    public let dimensions: Dimensions
    public let fps: Int
    public let useBroadcastExtension: Bool

    public init(dimensions: Dimensions = .h1080_169,
                fps: Int = 30,
                useBroadcastExtension: Bool = false
    ) {
        self.dimensions = dimensions
        self.fps = fps
        self.useBroadcastExtension = useBroadcastExtension
    }
}

public struct BufferCaptureOptions: VideoCaptureOptions {

    public let dimensions: Dimensions
    public let fps: Int

    public init(dimensions: Dimensions = .h1080_169,
                fps: Int = 30) {
        self.dimensions = dimensions
        self.fps = fps
    }

    public init(from options: ScreenShareCaptureOptions) {
        self.dimensions = options.dimensions
        self.fps = options.fps
    }
}

public struct AudioCaptureOptions: CaptureOptions {

    public let echoCancellation: Bool
    public let noiseSuppression: Bool
    public let autoGainControl: Bool
    public let typingNoiseDetection: Bool
    public let highpassFilter: Bool
    public let experimentalNoiseSuppression: Bool = false
    public let experimentalAutoGainControl: Bool = false

    public init(echoCancellation: Bool = true,
                noiseSuppression: Bool = false,
                autoGainControl: Bool = true,
                typingNoiseDetection: Bool = true,
                highpassFilter: Bool = true) {
        self.echoCancellation = echoCancellation
        self.noiseSuppression = noiseSuppression
        self.autoGainControl = autoGainControl
        self.typingNoiseDetection = typingNoiseDetection
        self.highpassFilter = highpassFilter
    }
}
