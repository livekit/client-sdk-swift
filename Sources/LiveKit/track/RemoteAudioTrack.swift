import WebRTC
import Promises

class RemoteAudioTrack: AudioTrack {

    override func start() -> Promise<Void> {
        // enable first then,
        // mark started by calling super
        Promise<Void> {
            super.enable()
        }.then {
            super.start()
        }
    }

    override func stop() -> Promise<Void> {
        // disable first then,
        // mark stopped by calling super
        Promise<Void> {
            super.disable()
        }.then {
            super.stop()
        }
    }
}
