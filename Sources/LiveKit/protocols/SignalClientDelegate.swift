import Foundation
import WebRTC

protocol SignalClientDelegate: AnyObject {
    func signalDidReceive(joinResponse: Livekit_JoinResponse)
    func signalDidReceive(answer: RTCSessionDescription)
    func signalDidReceive(offer: RTCSessionDescription)
    func signalDidReceive(iceCandidate: RTCIceCandidate, target: Livekit_SignalTarget)
    func signalDidPublish(localTrack: Livekit_TrackPublishedResponse)
    func signalDidUpdate(participants: [Livekit_ParticipantInfo])
    func signalDidUpdate(speakers: [Livekit_SpeakerInfo])
    func signalDidClose(reason: String, code: UInt16)
    func signalDidUpdateRemoteMute(trackSid: String, muted: Bool)
    func signalDidConnect(isReconnect: Bool)
    func signalDidLeave()
    func signalError(error: Error)
}

extension SignalClientDelegate {
    func signalDidReceive(joinResponse: Livekit_JoinResponse) {}
    func signalDidReceive(answer: RTCSessionDescription) {}
    func signalDidReceive(offer: RTCSessionDescription) {}
    func signalDidReceive(iceCandidate: RTCIceCandidate, target: Livekit_SignalTarget) {}
    func signalDidPublish(localTrack: Livekit_TrackPublishedResponse) {}
    func signalDidUpdate(participants: [Livekit_ParticipantInfo]) {}
    func signalDidUpdate(speakers: [Livekit_SpeakerInfo]) {}
    func signalDidUpdateRemoteMute(trackSid: String, muted: Bool) {}
    func signalDidLeave() {}
    // webSocket events
    func signalDidConnect(isReconnect: Bool) {}
    func signalDidClose(reason: String, code: UInt16) {}
    func signalError(error: Error) {}
}

class SignalClientDelegateClosures: NSObject, SignalClientDelegate {

    typealias DidConnect = (Bool) -> Void
    typealias DidPublishLocalTrack = (Livekit_TrackPublishedResponse) -> Void

    let didConnect: DidConnect?
    let didPublishLocalTrack: DidPublishLocalTrack?

    init(didConnect: DidConnect? = nil,
         didPublishLocalTrack: DidPublishLocalTrack? = nil) {
        logger.debug("[SignalClientDelegateClosures] init")
        self.didConnect = didConnect
        self.didPublishLocalTrack = didPublishLocalTrack
    }

    deinit {
        logger.debug("[SignalClientDelegateClosures] deinit")
    }

    func signalDidConnect(isReconnect: Bool) {
        didConnect?(isReconnect)
    }

    func signalDidPublish(localTrack: Livekit_TrackPublishedResponse) {
        didPublishLocalTrack?(localTrack)
    }
}
