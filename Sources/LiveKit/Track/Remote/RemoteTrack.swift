import Promises

public class RemoteTrack: Track {

    @discardableResult
    override func start() -> Promise<Void> {
        super.start().then {
            super.enable()
        }
    }

    @discardableResult
    override public func stop() -> Promise<Void> {
        super.stop().then {
            super.disable()
        }
    }
}
