import Foundation
import WebRTC

internal protocol EngineDelegate {
    func engine(_ engine: Engine, didUpdate connectionState: ConnectionState)
    func engine(_ engine: Engine, didReceive joinResponse: Livekit_JoinResponse)
    func engine(_ engine: Engine, didUpdateEngine speakers: [Livekit_SpeakerInfo])
    func engine(_ engine: Engine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream])
    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket)
    func engine(_ engine: Engine, didUpdate dataChannel: RTCDataChannel, state: RTCDataChannelState)
}

// MARK: - Optional

extension EngineDelegate {
    func engine(_ engine: Engine, didReceive joinResponse: Livekit_JoinResponse) {}
    func engine(_ engine: Engine, didUpdateEngine speakers: [Livekit_SpeakerInfo]) {}
    func engine(_ engine: Engine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {}
    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket) {}
    func engine(_ engine: Engine, didUpdate connectionState: ConnectionState) {}
    func engine(_ engine: Engine, didUpdate dataChannel: RTCDataChannel, state: RTCDataChannelState) {}
}

// MARK: - Closures

class EngineDelegateClosures: NSObject, EngineDelegate, Loggable {

    typealias DidUpdateDataChannelState = (_ engine: Engine,
                                           _ dataChannel: RTCDataChannel,
                                           _ state: RTCDataChannelState) -> Void

    let didUpdateDataChannelState: DidUpdateDataChannelState?

    init(didUpdateDataChannelState: DidUpdateDataChannelState? = nil) {

        self.didUpdateDataChannelState = didUpdateDataChannelState
        super.init()
        log()
    }
    
    deinit {
        log()
    }

    func engine(_ engine: Engine, didUpdate dataChannel: RTCDataChannel, state: RTCDataChannelState) {
        didUpdateDataChannelState?(engine, dataChannel, state)
    }
}
