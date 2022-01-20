import Foundation
import WebRTC

internal protocol SignalClientDelegate {

    func signalClient(_ signalClient: SignalClient, didUpdate connectionState: ConnectionState)
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
    func signalClient(_ signalClient: SignalClient, didReceiveLeave canReconnect: Bool)
}

// MARK: - Optional

extension SignalClientDelegate {

    func signalClient(_ signalClient: SignalClient, didUpdate connectionState: ConnectionState) {}
    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse) {}
    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: RTCSessionDescription) {}
    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: RTCSessionDescription) {}
    func signalClient(_ signalClient: SignalClient, didReceive iceCandidate: RTCIceCandidate, target: Livekit_SignalTarget) {}
    func signalClient(_ signalClient: SignalClient, didPublish localTrack: Livekit_TrackPublishedResponse) {}
    func signalClient(_ signalClient: SignalClient, didUpdate participants: [Livekit_ParticipantInfo]) {}
    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo]) {}
    func signalClient(_ signalClient: SignalClient, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo]) {}
    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool) {}
    func signalClient(_ signalClient: SignalClient, didUpdate trackStates: [Livekit_StreamStateInfo]) {}
    func signalClient(_ signalClient: SignalClient, didUpdate trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) {}
    func signalClient(_ signalClient: SignalClient, didUpdate subscriptionPermission: Livekit_SubscriptionPermissionUpdate) {}
    func signalClient(_ signalClient: SignalClient, didReceiveLeave canReconnect: Bool) {}
}

// MARK: - Closures

class SignalClientDelegateClosures: NSObject, SignalClientDelegate, Loggable {

    typealias DidUpdateConnectionState = (SignalClient, ConnectionState) -> Void
    typealias DidReceiveJoinResponse = (SignalClient, Livekit_JoinResponse) -> Void
    typealias DidPublishLocalTrack = (SignalClient, Livekit_TrackPublishedResponse) -> Void

    let didUpdateConnectionState: DidUpdateConnectionState?
    let didReceiveJoinResponse: DidReceiveJoinResponse?
    let didPublishLocalTrack: DidPublishLocalTrack?

    init(didUpdateConnectionState: DidUpdateConnectionState? = nil,
         didReceiveJoinResponse: DidReceiveJoinResponse? = nil,
         didPublishLocalTrack: DidPublishLocalTrack? = nil) {

        self.didUpdateConnectionState = didUpdateConnectionState
        self.didReceiveJoinResponse = didReceiveJoinResponse
        self.didPublishLocalTrack = didPublishLocalTrack
        super.init()
        log()
    }

    deinit {
        log()
    }

    func signalClient(_ signalClient: SignalClient, didUpdate connectionState: ConnectionState) {
        didUpdateConnectionState?(signalClient, connectionState)
    }

    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse) {
        didReceiveJoinResponse?(signalClient, joinResponse)
    }

    func signalClient(_ signalClient: SignalClient, didPublish localTrack: Livekit_TrackPublishedResponse) {
        didPublishLocalTrack?(signalClient, localTrack)
    }
}
