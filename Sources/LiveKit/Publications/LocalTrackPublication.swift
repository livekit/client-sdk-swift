import Foundation
import Promises

public class LocalTrackPublication: TrackPublication {

    @discardableResult
    public func mute() -> Promise<Void> {

        guard let track = track as? LocalTrack else {
            return Promise(InternalError.state("track is nil or not a LocalTrack"))
        }

        return track.mute()
    }

    @discardableResult
    public func unmute() -> Promise<Void> {

        guard let track = track as? LocalTrack else {
            return Promise(InternalError.state("track is nil or not a LocalTrack"))
        }

        return track.unmute()
    }

    #if LK_COMPUTE_VIDEO_SENDER_PARAMETERS

    // keep reference to cancel later
    private weak var debounceWorkItem: DispatchWorkItem?

    deinit {
        debounceWorkItem?.cancel()
    }

    // create debounce func
    lazy var shouldRecomputeSenderParameters = Utils.createDebounceFunc(wait: 0.1, onCreateWorkItem: { [weak self] workItem in
        self?.debounceWorkItem = workItem
    }, fnc: { [weak self] in
        self?.recomputeSenderParameters()
    })

    public override func track(_ track: Track, capturer: VideoCapturer, didUpdate dimensions: Dimensions?) {
        shouldRecomputeSenderParameters()
    }
    #endif
}

#if LK_COMPUTE_VIDEO_SENDER_PARAMETERS

extension LocalTrackPublication {

    internal func recomputeSenderParameters() {

        guard let track = track as? LocalVideoTrack,
              let sender = track.transceiver?.sender else { return }

        guard let participant = participant else { return }

        logger.debug("Re-computing sender parameters...")

        // get current parameters
        let parameters = sender.parameters

        // re-compute encodings
        let encodings = Utils.computeEncodings(dimensions: track.capturer.dimensions,
                                               publishOptions: track.publishOptions)

        for current in parameters.encodings {
            if let new = encodings?.first(where: { $0.rid == current.rid }) {
                // update parameters for matching rid
                current.isActive = new.isActive
                current.scaleResolutionDownBy = new.scaleResolutionDownBy
                current.maxBitrateBps = new.maxBitrateBps
                current.maxFramerate = new.maxFramerate
            }
        }

        // TODO: Investigate if WebRTC iOS SDK actually uses this value
        // parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.disabled.rawValue)

        // set the updated parameters
        sender.parameters = parameters

        logger.debug("Sender parameters updated: \(sender.parameters.encodings)")

        // Report updated encodings to server

        let layers = Utils.videoLayersForEncodings(dimensions: track.capturer.dimensions,
                                                   encodings: encodings)

        logger.debug("Sending update video layers request: \(layers)")

        participant.room.engine.signalClient.sendUpdateVideoLayers(trackSid: sid,
                                                                   layers: layers)
    }
}

#endif
