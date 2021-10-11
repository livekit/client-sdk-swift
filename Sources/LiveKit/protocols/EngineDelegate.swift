import Foundation
import WebRTC

protocol RTCEngineDelegate {
    func engineDidConnect(_ engine: RTCEngine)
    func engineDidReconnect(_ engine: RTCEngine)
    func engineDidDisconnect(_ engine: RTCEngine)
    func didFailToConnect(error: Error)
    func engine(_ engine: RTCEngine, didReceive joinResponse: Livekit_JoinResponse)
    func engine(_ engine: RTCEngine, didUpdate participants: [Livekit_ParticipantInfo])
    func engine(_ engine: RTCEngine, didUpdateEngine speakers: [Livekit_SpeakerInfo])
    func engine(_ engine: RTCEngine, didUpdateSignal speakers: [Livekit_SpeakerInfo])
    func engine(_ engine: RTCEngine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream])
    func engine(_ engine: RTCEngine, didReceive userPacket: Livekit_UserPacket)
    func engine(_ engine: RTCEngine, didUpdateRemoteMute trackSid: String, muted: Bool)
}
