import Foundation
import Promises

public class LocalTrackPublication: TrackPublication {

    @discardableResult
    public func mute() -> Promise<Void> {

        guard let track = track as? LocalTrack else {
            return Promise(InternalError.state(message: "track is nil or not a LocalTrack"))
        }

        return track.mute()
    }

    @discardableResult
    public func unmute() -> Promise<Void> {

        guard let track = track as? LocalTrack else {
            return Promise(InternalError.state(message: "track is nil or not a LocalTrack"))
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
        super.track(track, capturer: capturer, didUpdate: dimensions)
        shouldRecomputeSenderParameters()
    }
    #endif
}

#if LK_COMPUTE_VIDEO_SENDER_PARAMETERS

extension LocalTrackPublication {

    internal func recomputeSenderParameters() {

        guard let track = track as? LocalVideoTrack,
              let sender = track.transceiver?.sender else { return }

        guard let dimensions = track.capturer.dimensions else {
            log("Cannot re-compute sender parameters without dimensions", .warning)
            return
        }

        log("Re-computing sender parameters, dimensions: \(String(describing: track.capturer.dimensions))")

        // get current parameters
        let parameters = sender.parameters

        // re-compute encodings
        let encodings = Utils.computeEncodings(dimensions: dimensions,
                                               publishOptions: track.publishOptions as? VideoPublishOptions,
                                               isScreenShare: track.source == .screenShareVideo)

        log("Computed encodings: \(encodings)")

        for current in parameters.encodings {
            //
            if let updated = encodings.first(where: { $0.rid == current.rid }) {
                // update parameters for matching rid
                current.isActive = updated.isActive
                current.scaleResolutionDownBy = updated.scaleResolutionDownBy
                current.maxBitrateBps = updated.maxBitrateBps
                current.maxFramerate = updated.maxFramerate
            } else {
                current.isActive = false
                current.scaleResolutionDownBy = nil
                current.maxBitrateBps = nil
                current.maxBitrateBps = nil
            }
        }

        // TODO: Investigate if WebRTC iOS SDK actually uses this value
        // parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.disabled.rawValue)

        // set the updated parameters
        sender.parameters = parameters

        log("Using encodings: \(sender.parameters.encodings)")

        // Report updated encodings to server

        let layers = dimensions.videoLayers(for: encodings)

        self.log("Using encodings layers: \(layers.map { String(describing: $0) }.joined(separator: ", "))")

        participant.room.engine.signalClient.sendUpdateVideoLayers(trackSid: track.sid!,
                                                                   layers: layers).catch { error in
                                                                    self.log("Failed to send update video layers", .error)
                                                                   }
    }
}

#endif
