import Foundation
import WebRTC

internal protocol EngineDelegate {
    func engine(_ engine: Engine, didReceive joinResponse: Livekit_JoinResponse)
    func engine(_ engine: Engine, didUpdate participants: [Livekit_ParticipantInfo])
    func engine(_ engine: Engine, didUpdateEngine speakers: [Livekit_SpeakerInfo])
    func engine(_ engine: Engine, didUpdateSignal speakers: [Livekit_SpeakerInfo])
    func engine(_ engine: Engine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream])
    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket)
    func engine(_ engine: Engine, didUpdateRemoteMute trackSid: String, muted: Bool)
    func engine(_ engine: Engine, didConnect isReconnect: Bool)
    func engine(_ engine: Engine, didFailConnection error: Error)
    func engineDidDisconnect(_ engine: Engine)
}
