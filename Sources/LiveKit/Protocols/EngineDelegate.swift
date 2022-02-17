import Foundation
import WebRTC

internal protocol EngineDelegate {
    func engine(_ engine: Engine, didUpdate connectionState: ConnectionState, oldState: ConnectionState)
    func engine(_ engine: Engine, didUpdate speakers: [Livekit_SpeakerInfo])
    func engine(_ engine: Engine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream])
    func engine(_ engine: Engine, didRemove track: RTCMediaStreamTrack)
    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket)
    func engine(_ engine: Engine, didUpdate dataChannel: RTCDataChannel, state: RTCDataChannelState)
    func engine(_ engine: Engine, didGenerate stats: [TrackStats], target: Livekit_SignalTarget)
}

// MARK: - Optional

extension EngineDelegate {
    func engine(_ engine: Engine, didUpdate connectionState: ConnectionState, oldState: ConnectionState) {}
    func engine(_ engine: Engine, didUpdate speakers: [Livekit_SpeakerInfo]) {}
    func engine(_ engine: Engine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {}
    func engine(_ engine: Engine, didRemove track: RTCMediaStreamTrack) {}
    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket) {}
    func engine(_ engine: Engine, didUpdate dataChannel: RTCDataChannel, state: RTCDataChannelState) {}
    func engine(_ engine: Engine, didGenerate stats: [TrackStats], target: Livekit_SignalTarget) {}
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
