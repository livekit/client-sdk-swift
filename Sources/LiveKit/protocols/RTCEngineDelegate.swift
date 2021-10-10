import Foundation
import WebRTC

protocol RTCEngineDelegate {
    func didJoin(response: Livekit_JoinResponse)
    func ICEDidConnect()
    func ICEDidReconnect()
    func didAddTrack(track: RTCMediaStreamTrack, streams: [RTCMediaStream])
    func didUpdateParticipants(updates: [Livekit_ParticipantInfo])
    func didUpdateSpeakersEngine(speakers: [Livekit_SpeakerInfo])
    func didUpdateSpeakersSignal(speakers: [Livekit_SpeakerInfo])
    func didDisconnect()
    func didFailToConnect(error: Error)
    func didReceive(userPacket: Livekit_UserPacket, kind: Livekit_DataPacket.Kind)
    func remoteMuteDidChange(trackSid: String, muted: Bool)
}
