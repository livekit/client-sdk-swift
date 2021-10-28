import WebRTC
import Promises

class RemoteVideoTrack: VideoTrack {

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
        Promise<Void> {
            super.disable()
        }.then {
            super.stop()
        }
    }
}
