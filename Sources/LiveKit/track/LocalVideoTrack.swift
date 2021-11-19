import Foundation
import WebRTC
import Promises
import ReplayKit

public class LocalVideoTrack: VideoTrack {

    public internal(set) var capturer: VideoCapturer
    public internal(set) var videoSource: RTCVideoSource

    internal init(capturer: VideoCapturer,
                  videoSource: RTCVideoSource,
                  name: String,
                  source: Track.Source) {

        let rtcTrack = Engine.factory.videoTrack(with: videoSource, trackId: UUID().uuidString)
        rtcTrack.isEnabled = true

        self.capturer = capturer
        self.videoSource = videoSource
        super.init(rtcTrack: rtcTrack, name: name, source: source)

        self.capturer.add(delegate: self)
    }

    public override var transceiver: RTCRtpTransceiver? {
        didSet {
            guard oldValue != transceiver,
                  transceiver != nil else { return }
            self.recomputeSenderParameters()
        }
    }

    @available(*, deprecated, message: "Use CameraCapturer's methods instead to switch cameras")
    public func restartTrack(options: LocalVideoTrackOptions = LocalVideoTrackOptions()) -> Promise<Void> {
        guard let capturer = capturer as? CameraCapturer else {
            return Promise(TrackError.invalidTrackState("Must be an CameraCapturer"))
        }
        capturer.options = options
        return capturer.restartCapture()
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
        self.recomputeSenderParameters()
    }

    internal func recomputeSenderParameters() {
        print("Should re-compute sender parameters")
        guard let sender = transceiver?.sender else {return}

        // get current parameters
        let parameters = sender.parameters
        print("re-compute: \(sender.parameters.encodings)")

        // TODO: Update parameters

        parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.disabled.rawValue)

        // set the updated parameters
        sender.parameters = parameters

        print("re-compute: \(sender.parameters.encodings)")

    }
}
