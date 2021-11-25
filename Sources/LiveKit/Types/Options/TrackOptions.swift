import Foundation
import WebRTC

public struct LocalVideoTrackOptions {
    public var position: AVCaptureDevice.Position = .front
    public var captureFormat: AVCaptureDevice.Format?
    public var captureParameter = VideoParameters.presetQHD169

    public init() {}
}

public struct LocalAudioTrackOptions {
    public var noiseSuppression: Bool = true
    public var echoCancellation: Bool = true
    public var audoGainControl: Bool = true
    public var typingNoiseDetection: Bool = true
    public var highpassFilter: Bool = true
    public var experimentalNoiseSuppression: Bool = false
    public var experimentalAutoGainControl: Bool = false

    public init() {}
}
