import Foundation
import Promises
import WebRTC

internal class SignalClient: MulticastDelegate<SignalClientDelegate> {

    public private(set) var connectionState: ConnectionState = .disconnected() {
        didSet {
            guard oldValue != connectionState else { return }
            // Connected
            if case .connected = connectionState {
                // Check if this was a re-connect
                var isReconnect = false
                if case .connecting(let reconnecting) = oldValue, reconnecting {
                    isReconnect = true
                }

                notify { $0.signalClient(self, didConnect: isReconnect) }
            }

            if case .disconnected = connectionState {
                if case .connecting = oldValue {
                    // Failed to connect
                    notify { $0.signalClient(self, didFailConnect: SignalClientError.close()) }
                } else if case .connected = oldValue {
                    // Disconnected
                    notify { $0.signalClient(self, didClose: .abnormalClosure) }
                }

                webSocket?.close()
                webSocket = nil
            }
        }
    }

    private var webSocket: WebSocket?
    private var latestJoinResponse: Livekit_JoinResponse?

    func connect(_ url: String,
                 _ token: String,
                 connectOptions: ConnectOptions? = nil,
                 reconnect: Bool = false) -> Promise<Void> {

        // Clear internal vars
        self.latestJoinResponse = nil
        self.connectionState = .connecting(isReconnecting: reconnect)

        return Promise { () -> URL in
            try Utils.buildUrl(url,
                               token,
                               connectOptions: connectOptions,
                               reconnect: reconnect)
        }.then { (url: URL) -> Promise<WebSocket> in
            logger.debug("Connecting with url: \(url)")
            return WebSocket.connect(url: url,
                                     onMessage: self.onWebSocketMessage) { _ in
                // onClose
                self.connectionState = .disconnected()
            }
        }.then { (webSocket: WebSocket) -> Void in
            self.webSocket = webSocket
            self.connectionState = .connected
        }.catch { error in
            self.connectionState = .disconnected(error)
        }
    }

    private func sendRequest(_ request: Livekit_SignalRequest) {

        guard case .connected = connectionState else {
            logger.error("could not send message, not connected")
            return
        }

        guard let data = try? request.serializedData() else {
            logger.error("could not serialize data")
            return
        }

        webSocket?.send(data: data)
    }

    func close() {
        connectionState = .disconnected()
    }

    private func onWebSocketMessage(message: URLSessionWebSocketTask.Message) {

        var response: Livekit_SignalResponse?

        switch message {
        case .data(let data):
            response = try? Livekit_SignalResponse(contiguousBytes: data)
        case .string(let text):
            response = try? Livekit_SignalResponse(jsonString: text)
        @unknown default:
            // This should never happen
            logger.warning("Unknown message type")
        }

        guard let response = response else {
            logger.warning("Failed to decode SignalResponse")
            return
        }

        if let message = response.message {
            onSignalResponse(message: message)
        }
    }

    private func onSignalResponse(message: Livekit_SignalResponse.OneOf_Message) {

        guard case .connected = connectionState else {
            logger.error("not connected")
            return
        }

        do {
            switch message {
            case .join(let joinResponse) :
                latestJoinResponse = joinResponse
                notify { $0.signalClient(self, didReceive: joinResponse) }

            case .answer(let sd):
                try notify { $0.signalClient(self, didReceiveAnswer: try sd.toRTCType()) }

            case .offer(let sd):
                try notify { $0.signalClient(self, didReceiveOffer: try sd.toRTCType()) }

            case .trickle(let trickle):
                let rtcCandidate = try RTCIceCandidate(fromJsonString: trickle.candidateInit)
                notify { $0.signalClient(self, didReceive: rtcCandidate, target: trickle.target) }

            case .update(let update):
                notify { $0.signalClient(self, didUpdate: update.participants) }

            case .trackPublished(let trackPublished):
                notify { $0.signalClient(self, didPublish: trackPublished) }

            case .speakersChanged(let speakers):
                notify { $0.signalClient(self, didUpdate: speakers.speakers) }

            case .connectionQuality(let quality):
                notify { $0.signalClient(self, didUpdate: quality.updates) }

            case .mute(let mute):
                notify { $0.signalClient(self, didUpdateRemoteMute: mute.sid, muted: mute.muted) }

            case .leave:
                notify { $0.signalClientDidLeave(self) }

            case .streamStateUpdate(let states):
                notify { $0.signalClient(self, didUpdate: states.streamStates) }

            case .subscribedQualityUpdate(let update):
                // ignore 0.15.1
                if latestJoinResponse?.serverVersion == "0.15.1" {
                    return
                }
                notify { $0.signalClient(self, didUpdate: update.trackSid, subscribedQualities: update.subscribedQualities)}
            case .subscriptionPermissionUpdate(let permissionUpdate):
                notify { $0.signalClient(self, didUpdate: permissionUpdate) }
            default:
                logger.warning("unsupported signal response type: \(message)")
            }
        } catch {
            logger.error("could not handle signal response: \(error)")
        }
    }
}

// MARK: Wait extension

extension SignalClient {

    func waitReceiveJoinResponse() -> Promise<Livekit_JoinResponse> {

        logger.debug("Waiting for join response...")

        // If already received a join response, there is no need to wait.
        if let joinResponse = latestJoinResponse {
            logger.debug("Already received join response")
            return Promise(joinResponse)
        }

        return Promise<Livekit_JoinResponse> { resolve, _ in
            // create temporary delegate
            var delegate: SignalClientDelegateClosures?
            delegate = SignalClientDelegateClosures(didReceiveJoinResponse: { _, joinResponse in
                // wait until connected
                resolve(joinResponse)
                delegate = nil
            })
            // not required to clean up since weak reference
            self.add(delegate: delegate!)
        }
        // convert to a timed-promise
        .timeout(10)
    }
}

// MARK: - Send methods

extension SignalClient {

    func sendOffer(offer: RTCSessionDescription) throws {
        logger.debug("[SignalClient] Sending offer")

        let r = try Livekit_SignalRequest.with {
            $0.offer = try offer.toPBType()
        }

        sendRequest(r)
    }

    func sendAnswer(answer: RTCSessionDescription) throws {
        logger.debug("[SignalClient] Sending answer")

        let r = try Livekit_SignalRequest.with {
            $0.answer = try answer.toPBType()
        }

        sendRequest(r)
    }

    func sendCandidate(candidate: RTCIceCandidate, target: Livekit_SignalTarget) throws {
        logger.debug("[SignalClient] Sending ICE candidate")

        let r = try Livekit_SignalRequest.with {
            $0.trickle = try Livekit_TrickleRequest.with {
                $0.target = target
                $0.candidateInit = try candidate.toLKType().toJsonString()
            }
        }

        sendRequest(r)
    }

    func sendMuteTrack(trackSid: String, muted: Bool) {
        logger.debug("[SignalClient] Sending mute for \(trackSid), muted: \(muted)")

        let r = Livekit_SignalRequest.with {
            $0.mute = Livekit_MuteTrackRequest.with {
                $0.sid = trackSid
                $0.muted = muted
            }
        }

        sendRequest(r)
    }

    func sendAddTrack(cid: String,
                      name: String,
                      type: Livekit_TrackType,
                      source: Livekit_TrackSource = .unknown,
                      _ populator: (inout Livekit_AddTrackRequest) -> Void) {
        logger.debug("[SignalClient] Sending add track request")
        let r = Livekit_SignalRequest.with {
            $0.addTrack = Livekit_AddTrackRequest.with {
                populator(&$0)
                $0.cid = cid
                $0.name = name
                $0.type = type
                $0.source = source
            }
        }

        sendRequest(r)
    }

    func sendUpdateTrackSettings(sid: String,
                                 enabled: Bool,
                                 width: Int = 0,
                                 height: Int = 0) {
        logger.debug("[SignalClient] Sending update track settings")

        let r = Livekit_SignalRequest.with {
            $0.trackSetting = Livekit_UpdateTrackSettings.with {
                $0.trackSids = [sid]
                $0.disabled = !enabled
                $0.width = UInt32(width) // unlikely to overflow
                $0.height = UInt32(height) // unlikely to overflow
            }
        }

        sendRequest(r)
    }

    func sendUpdateVideoLayers(trackSid: String,
                               layers: [Livekit_VideoLayer]) {

        let r = Livekit_SignalRequest.with {
            $0.updateLayers = Livekit_UpdateVideoLayers.with {
                $0.trackSid = trackSid
                $0.layers = layers
            }
        }

        sendRequest(r)
    }

    func sendUpdateSubscription(sid: String, subscribed: Bool) {
        logger.debug("[SignalClient] Sending update subscription")

        let r = Livekit_SignalRequest.with {
            $0.subscription = Livekit_UpdateSubscription.with {
                $0.trackSids = [sid]
                $0.subscribe = subscribed
            }
        }

        sendRequest(r)
    }

    func sendUpdateSubscriptionPermissions(allParticipants: Bool, participantTrackPermissions: [ParticipantTrackPermission]) {
        let r = Livekit_SignalRequest.with {
            $0.subscriptionPermissions = Livekit_UpdateSubscriptionPermissions.with {
                $0.allParticipants = allParticipants
                $0.trackPermissions = participantTrackPermissions.map({ $0.toPBType() })
            }
        }

        sendRequest(r)
    }
    func sendLeave() {
        logger.debug("[SignalClient] Sending leave")

        let r = Livekit_SignalRequest.with {
            $0.leave = Livekit_LeaveRequest()
        }

        sendRequest(r)
    }
}
