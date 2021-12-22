import Foundation
import WebRTC
import Promises
import ReplayKit

public class LocalVideoTrack: LocalTrack, VideoTrack {

    public internal(set) var capturer: VideoCapturer
    public internal(set) var videoSource: RTCVideoSource

    internal init(name: String,
                  source: Track.Source,
                  capturer: VideoCapturer,
                  videoSource: RTCVideoSource) {

        let rtcTrack = Engine.factory.videoTrack(with: videoSource, trackId: UUID().uuidString)
        rtcTrack.isEnabled = true

        self.capturer = capturer
        self.videoSource = videoSource

        super.init(name: name,
                   kind: .video,
                   source: source,
                   track: rtcTrack)

        self.capturer.add(delegate: self)
    }

    public override func start() -> Promise<Void> {
        super.start().then {
            self.capturer.startCapture()
        }
    }

    public override func stop() -> Promise<Void> {
        super.stop().then {
            self.capturer.stopCapture()
        }
    }
}

// MARK: - Re-compute sender parameters

extension LocalVideoTrack: VideoCapturerDelegate {
    // watch for dimension changes to re-compute sender parameters
    public func capturer(_ capturer: VideoCapturer, didUpdate dimensions: Dimensions?) {
        // relay the event
        notify { $0.track(self, capturer: capturer, didUpdate: dimensions) }
    }
}

extension RTCRtpEncodingParameters {
    open override var description: String {
        return "RTCRtpEncodingParameters(rid: \(rid ?? "-"), "
            + "active: \(isActive),"
            + "maxBitrateBps: \(maxBitrateBps ?? 0), "
            + "maxFramerate: \(maxFramerate ?? 0))"
    }
}

// MARK: - Deprecated methods

extension LocalVideoTrack {

    @available(*, deprecated, message: "Use CameraCapturer's methods instead to switch cameras")
    public func restartTrack(options: VideoCaptureOptions = VideoCaptureOptions()) -> Promise<Void> {
        guard let capturer = capturer as? CameraCapturer else {
            return Promise(TrackError.invalidTrackState("Must be an CameraCapturer"))
        }
        capturer.options = options
        return capturer.restartCapture()
    }
}
