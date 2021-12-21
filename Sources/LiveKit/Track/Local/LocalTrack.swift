import Promises

public class LocalTrack: Track {

    public func mute() -> Promise<Void> {
        // Already muted
        if muted { return Promise(()) }

        return disable().then {
            self.stop()
        }.then {
            self.update(muted: true, shouldSendSignal: true)
        }
    }

    public func unmute() -> Promise<Void> {
        // Already un-muted
        if !muted { return Promise(()) }

        return enable().then {
            self.start()
        }.then {
            self.update(muted: false, shouldSendSignal: true)
        }
    }
}
