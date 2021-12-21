import WebRTC
import Promises

class RemoteAudioTrack: RemoteTrack, AudioTrack {

    init(name: String,
         source: Track.Source,
         track: RTCMediaStreamTrack) {

        super.init(name: name,
                   kind: .audio,
                   source: source,
                   track: track)
    }

    @discardableResult
    override func start() -> Promise<Void> {
        super.start().then {
            AudioManager.shared.trackDidStart(.remote)
        }
    }

    @discardableResult
    override public func stop() -> Promise<Void> {
        super.stop().then {
            AudioManager.shared.trackDidStop(.remote)
        }
    }
}
