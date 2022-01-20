import Foundation
import WebRTC

internal protocol EngineDelegate {
    func engine(_ engine: Engine, didReceive joinResponse: Livekit_JoinResponse)
    func engine(_ engine: Engine, didUpdateEngine speakers: [Livekit_SpeakerInfo])
    func engine(_ engine: Engine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream])
    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket)
    func engine(_ engine: Engine, didUpdate connectionState: ConnectionState)
    func engine(_ engine: Engine, didUpdate dataChannel: RTCDataChannel, state: RTCDataChannelState)
    func engine(_ engine: Engine, didConnect isReconnect: Bool)
    func engine(_ engine: Engine, didFailConnection error: Error)
    func engineDidDisconnect(_ engine: Engine)
}

// MARK: - Optional

extension EngineDelegate {
    func engine(_ engine: Engine, didReceive joinResponse: Livekit_JoinResponse) {}
    func engine(_ engine: Engine, didUpdateEngine speakers: [Livekit_SpeakerInfo]) {}
    func engine(_ engine: Engine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {}
    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket) {}
    func engine(_ engine: Engine, didUpdate connectionState: ConnectionState) {}
    func engine(_ engine: Engine, didUpdate dataChannel: RTCDataChannel, state: RTCDataChannelState) {}
    func engine(_ engine: Engine, didConnect isReconnect: Bool) {}
    func engine(_ engine: Engine, didFailConnection error: Error) {}
    func engineDidDisconnect(_ engine: Engine) {}
}

// MARK: - Closures

class EngineDelegateClosures: NSObject, EngineDelegate {

    typealias OnDataChannelStateUpdated = (_ engine: Engine,
                                           _ dataChannel: RTCDataChannel,
                                           _ state: RTCDataChannelState) -> Void

    let onDataChannelStateUpdated: OnDataChannelStateUpdated?

    init(onDataChannelStateUpdated: OnDataChannelStateUpdated? = nil) {
        self.onDataChannelStateUpdated = onDataChannelStateUpdated
    }

    func engine(_ engine: Engine, didUpdate dataChannel: RTCDataChannel, state: RTCDataChannelState) {
        onDataChannelStateUpdated?(engine, dataChannel, state)
    }
}
