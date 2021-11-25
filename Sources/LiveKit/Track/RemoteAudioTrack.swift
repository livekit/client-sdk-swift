import WebRTC
import Promises

class RemoteAudioTrack: AudioTrack {

    @discardableResult
    override func start() -> Promise<Void> {
        // enable first then,
        // mark started by calling super
        Promise<Void> {
            super.enable()
        }.then {
            super.start()
        }
    }

    @discardableResult
    override public func stop() -> Promise<Void> {
        // disable first then,
        // mark stopped by calling super
        Promise<Void> {
            super.disable()
        }.then {
            super.stop()
        }
    }
}
