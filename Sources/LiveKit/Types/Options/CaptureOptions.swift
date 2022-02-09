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

    public let dimensions: Dimensions
    public let fps: Int

    public init(position: AVCaptureDevice.Position = .front,
                preferredFormat: AVCaptureDevice.Format? = nil,
                dimensions: Dimensions = .hd169,
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

    public init(dimensions: Dimensions = .hd169,
                fps: Int = 30) {

        self.dimensions = dimensions
        self.fps = fps
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
