import Promises

public class LocalTrack: Track {
    
    public enum PublishState {
        case unpublished
        case published
    }

    public private(set) var publishState: PublishState = .unpublished

    /// ``publishOptions`` used for this track if already published.
    public internal(set) var publishOptions: PublishOptions?

    public func mute() -> Promise<Void> {
        // Already muted
        if muted { return Promise(()) }

        return disable().then(on: .sdk) {
            self.stop()
        }.then(on: .sdk) {
            self.set(muted: true, shouldSendSignal: true)
        }
    }

    public func unmute() -> Promise<Void> {
        // Already un-muted
        if !muted { return Promise(()) }

        return enable().then(on: .sdk) {
            self.start()
        }.then(on: .sdk) {
            self.set(muted: false, shouldSendSignal: true)
        }
    }
    
    internal func publish() -> Promise<Void> {

        Promise(on: .sdk) {
            guard self.publishState != .published else {
                throw TrackError.state(message: "Already published")
            }

            self.publishState = .published
        }
    }

    internal func unpublish() -> Promise<Void> {

        Promise(on: .sdk) {
            guard self.publishState != .unpublished else {
                throw TrackError.state(message: "Already unpublished")
            }

            self.publishState = .unpublished
        }
    }
}
