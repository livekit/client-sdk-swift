import WebRTC
import Promises

class RemoteVideoTrack: VideoTrack {

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
        Promise<Void> {
            super.disable()
        }.then {
            super.stop()
        }
    }
}
