import Foundation
import WebRTC

public struct VideoCaptureOptions {
    public var position: AVCaptureDevice.Position
    public var captureFormat: AVCaptureDevice.Format?
    public var captureParameter: VideoParameters

    public init(position: AVCaptureDevice.Position = .front,
                captureFormat: AVCaptureDevice.Format? = nil,
                captureParameter: VideoParameters = .presetHD169) {
        self.position = position
        self.captureFormat = captureFormat
        self.captureParameter = captureParameter
    }
}

public struct AudioCaptureOptions {
    public var echoCancellation: Bool
    public var noiseSuppression: Bool
    public var autoGainControl: Bool
    public var typingNoiseDetection: Bool
    public var highpassFilter: Bool
    public var experimentalNoiseSuppression: Bool = false
    public var experimentalAutoGainControl: Bool = false

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
