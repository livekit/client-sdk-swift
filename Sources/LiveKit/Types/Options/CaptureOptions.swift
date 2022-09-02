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

@objc public protocol CaptureOptions {

}

@objc public protocol VideoCaptureOptions: CaptureOptions {
    var dimensions: Dimensions { get }
    var fps: Int { get }
}

@objc public class CameraCaptureOptions: NSObject, VideoCaptureOptions {

    public static func == (lhs: CameraCaptureOptions, rhs: CameraCaptureOptions) -> Bool {
        // TODO: Implement
        fatalError("Not implemented")
    }

    @objc public let position: AVCaptureDevice.Position
    @objc public let preferredFormat: AVCaptureDevice.Format?

    /// preferred dimensions for capturing, the SDK may override with a recommended value.
    @objc public let dimensions: Dimensions

    /// preferred fps to use for capturing, the SDK may override with a recommended value.
    @objc public let fps: Int

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

@objc public class ScreenShareCaptureOptions: NSObject, VideoCaptureOptions {

    public static func == (lhs: ScreenShareCaptureOptions, rhs: ScreenShareCaptureOptions) -> Bool {
        // TODO: Implement
        fatalError("Not implemented")
    }

    @objc public let dimensions: Dimensions
    @objc public let fps: Int
    @objc public let useBroadcastExtension: Bool

    public init(dimensions: Dimensions = .h1080_169,
                fps: Int = 30,
                useBroadcastExtension: Bool = false) {

        self.dimensions = dimensions
        self.fps = fps
        self.useBroadcastExtension = useBroadcastExtension
    }
}

@objc public class BufferCaptureOptions: NSObject, VideoCaptureOptions {

    public static func == (lhs: BufferCaptureOptions, rhs: BufferCaptureOptions) -> Bool {
        // TODO: Implement
        fatalError("Not implemented")
    }

    @objc public let dimensions: Dimensions
    @objc public let fps: Int

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

@objc public class AudioCaptureOptions: NSObject, CaptureOptions {

    public static func == (lhs: AudioCaptureOptions, rhs: AudioCaptureOptions) -> Bool {
        // TODO: Implement
        fatalError("Not implemented")
    }

    @objc public let echoCancellation: Bool
    @objc public let noiseSuppression: Bool
    @objc public let autoGainControl: Bool
    @objc public let typingNoiseDetection: Bool
    @objc public let highpassFilter: Bool
    @objc public let experimentalNoiseSuppression: Bool = false
    @objc public let experimentalAutoGainControl: Bool = false

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
