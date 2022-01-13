import Promises

public class RemoteTrack: Track {

    @discardableResult
    override func start() -> Promise<Void> {
        super.start().then(on: .sdk) {
            super.enable()
        }
    }

    @discardableResult
    override public func stop() -> Promise<Void> {
        super.stop().then(on: .sdk) {
            super.disable()
        }
    }
}
