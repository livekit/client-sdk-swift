import Foundation
import WebRTC

internal protocol SignalClientDelegate {
    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse)
    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: RTCSessionDescription)
    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: RTCSessionDescription)
    func signalClient(_ signalClient: SignalClient, didReceive iceCandidate: RTCIceCandidate, target: Livekit_SignalTarget)
    func signalClient(_ signalClient: SignalClient, didPublish localTrack: Livekit_TrackPublishedResponse)
    func signalClient(_ signalClient: SignalClient, didUpdate participants: [Livekit_ParticipantInfo])
    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo])
    func signalClient(_ signalClient: SignalClient, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo])
    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool)
    func signalClient(_ signalClient: SignalClient, didUpdate trackStates: [Livekit_StreamStateInfo])
    func signalClient(_ signalClient: SignalClient, didUpdate trackSid: String, subscribedQualities: [Livekit_SubscribedQuality])
    func signalClient(_ signalClient: SignalClient, didUpdate subscriptionPermission: Livekit_SubscriptionPermissionUpdate)
    func signalClientDidLeave(_ signaClient: SignalClient)
    func signalClient(_ signalClient: SignalClient, didClose code: URLSessionWebSocketTask.CloseCode)
    func signalClient(_ signalClient: SignalClient, didConnect isReconnect: Bool)
    func signalClient(_ signalClient: SignalClient, didFailConnection error: Error)
}

class SignalClientDelegateClosures: NSObject, SignalClientDelegate {

    typealias DidConnect = (SignalClient, Bool) -> Void
    typealias DidFailConnection = (SignalClient, Error) -> Void
    typealias DidClose = (SignalClient, URLSessionWebSocketTask.CloseCode) -> Void
    typealias DidReceiveJoinResponse = (SignalClient, Livekit_JoinResponse) -> Void
    typealias DidPublishLocalTrack = (SignalClient, Livekit_TrackPublishedResponse) -> Void

    let didConnect: DidConnect?
    let didFailConnection: DidFailConnection?
    let didClose: DidClose?
    let didReceiveJoinResponse: DidReceiveJoinResponse?
    let didPublishLocalTrack: DidPublishLocalTrack?

    init(didConnect: DidConnect? = nil,
         didFailConnection: DidFailConnection? = nil,
         didClose: DidClose? = nil,
         didReceiveJoinResponse: DidReceiveJoinResponse? = nil,
         didPublishLocalTrack: DidPublishLocalTrack? = nil) {
        logger.debug("[SignalClientDelegateClosures] init")
        self.didConnect = didConnect
        self.didFailConnection = didFailConnection
        self.didClose = didClose
        self.didReceiveJoinResponse = didReceiveJoinResponse
        self.didPublishLocalTrack = didPublishLocalTrack
    }

    deinit {
        logger.debug("[SignalClientDelegateClosures] deinit")
    }

    func signalClient(_ signalClient: SignalClient, didConnect isReconnect: Bool) {
        didConnect?(signalClient, isReconnect)
    }

    func signalClient(_ signalClient: SignalClient, didFailConnection error: Error) {
        didFailConnection?(signalClient, error)
    }

    func signalClient(_ signalClient: SignalClient, didClose code: URLSessionWebSocketTask.CloseCode) {
        didClose?(signalClient, code)
    }

    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse) {
        didReceiveJoinResponse?(signalClient, joinResponse)
    }

    func signalClient(_ signalClient: SignalClient, didPublish localTrack: Livekit_TrackPublishedResponse) {
        didPublishLocalTrack?(signalClient, localTrack)
    }

    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: RTCSessionDescription) {}
    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: RTCSessionDescription) {}
    func signalClient(_ signalClient: SignalClient, didReceive iceCandidate: RTCIceCandidate, target: Livekit_SignalTarget) {}
    func signalClient(_ signalClient: SignalClient, didUpdate participants: [Livekit_ParticipantInfo]) {}
    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo]) {}
    func signalClient(_ signalClient: SignalClient, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo]) {}
    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool) {}
    func signalClient(_ signalClient: SignalClient, didUpdate trackStates: [Livekit_StreamStateInfo]) {}
    func signalClient(_ signalClient: SignalClient, didUpdate trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) {}
    func signalClient(_ signalClient: SignalClient, didUpdate subscriptionPermission: Livekit_SubscriptionPermissionUpdate) {}
    func signalClientDidLeave(_ signaClient: SignalClient) {}
}
