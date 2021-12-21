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
}
