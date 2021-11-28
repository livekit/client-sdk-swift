import Foundation
import WebRTC

public struct LocalVideoTrackOptions {
    public var position: AVCaptureDevice.Position = .front
    public var captureFormat: AVCaptureDevice.Format?
    public var captureParameter = VideoParameters.presetQHD169

    public init() {}
}

public struct LocalAudioTrackOptions {
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
