import Foundation
import Promises
import WebRTC

internal class SignalClient: MulticastDelegate<SignalClientDelegate> {

    public private(set) var connectionState: ConnectionState = .disconnected(reason: .sdk) {
        didSet {
            guard oldValue != connectionState else { return }
            log("\(oldValue) -> \(self.connectionState)")
            notify { $0.signalClient(self, didUpdate: self.connectionState) }
        }
    }

    private var webSocket: WebSocket?
    private var latestJoinResponse: Livekit_JoinResponse?

    internal func cleanUp(reason: DisconnectReason) {
        log("reason: \(reason)")

        connectionState = .disconnected(reason: reason)

        if let socket = webSocket {
            socket.cleanUp(reason: reason)
            self.webSocket = nil
        }

        latestJoinResponse = nil
    }

    public func connect(_ url: String,
                        _ token: String,
                        connectOptions: ConnectOptions? = nil,
                        connectMode: ConnectMode = .normal) -> Promise<Void> {

        cleanUp(reason: .sdk)

        return Utils.buildUrl(url,
                              token,
                              connectOptions: connectOptions,
                              connectMode: connectMode)
            .catch(on: .sdk) { error in
                self.log("Failed to parse rtc url", .error)
            }
            .then(on: .sdk) { url -> Promise<WebSocket> in
                self.log("Connecting with url: \(url)")
                self.connectionState = .connecting(connectMode)
                return WebSocket.connect(url: url,
                                         onMessage: self.onWebSocketMessage,
                                         onDisconnect: { reason in
                                            self.webSocket = nil
                                            self.cleanUp(reason: reason)
                                         })
            }.then(on: .sdk) { (webSocket: WebSocket) -> Void in
                self.webSocket = webSocket
                self.connectionState = .connected(connectMode)
            }.recover(on: .sdk) { error -> Promise<Void> in
                // Skip validation if reconnect mode
                if case .reconnect = connectMode { throw error }
                // Catch first, then throw again after getting validation response
                // Re-build url with validate mode
                return Utils.buildUrl(url,
                                      token,
                                      connectOptions: connectOptions,
                                      connectMode: connectMode,
                                      validate: true
                ).then(on: .sdk) { url -> Promise<Data> in
                    self.log("Validating with url: \(url)")
                    return HTTP().get(url: url)
                }.then(on: .sdk) { data in
                    guard let string = String(data: data, encoding: .utf8) else {
                        throw SignalClientError.connect(message: "Failed to decode string")
                    }
                    self.log("validate response: \(string)")
                    // re-throw with validation response
                    throw SignalClientError.connect(message: string)
                }
            }.catch(on: .sdk) { _ in
                self.cleanUp(reason: .network())
            }
    }

    private func sendRequest(_ request: Livekit_SignalRequest) -> Promise<Void> {

        guard case .connected = connectionState else {
            log("Not connected", .error)
            return Promise(SignalClientError.state(message: "Not connected"))
        }

        guard let webSocket = webSocket else {
            log("WebSocket is nil", .error)
            return Promise(SignalClientError.state(message: "WebSocket is nil"))
        }

        guard let data = try? request.serializedData() else {
            log("Could not serialize data", .error)
            return Promise(InternalError.convert(message: "Could not serialize data"))
        }

        return webSocket.send(data: data)
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
            log("Unknown message type", .warning)
        }

        guard let response = response,
              let message = response.message else {
            log("Failed to decode SignalResponse", .warning)
            return
        }

        onSignalResponse(message: message)
    }

    private func onSignalResponse(message: Livekit_SignalResponse.OneOf_Message) {

        guard case .connected = connectionState else {
            log("Not connected", .warning)
            return
        }

        switch message {
        case .join(let joinResponse) :
            latestJoinResponse = joinResponse
            notify { $0.signalClient(self, didReceive: joinResponse) }

        case .answer(let sd):
            notify { $0.signalClient(self, didReceiveAnswer: sd.toRTCType()) }

        case .offer(let sd):
            notify { $0.signalClient(self, didReceiveOffer: sd.toRTCType()) }

        case .trickle(let trickle):
            guard let rtcCandidate = try? Engine.createIceCandidate(fromJsonString: trickle.candidateInit) else {
                return
            }

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

        case .leave(let leave):
            notify { $0.signalClient(self, didReceiveLeave: leave.canReconnect) }

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
        case .refreshToken(let token):
            notify { $0.signalClient(self, didUpdate: token) }
        default:
            log("Unhandled signal message: \(message)", .warning)
        }
    }
}

// MARK: Wait extension

internal extension SignalClient {

    func waitReceiveJoinResponse() -> Promise<Livekit_JoinResponse> {

        log("Waiting for join response...")

        // If already received a join response, there is no need to wait.
        if let joinResponse = latestJoinResponse {
            log("Already received join response")
            return Promise(joinResponse)
        }

        return Promise<Livekit_JoinResponse>(on: .sdk) { resolve, _ in
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
        .timeout(.defaultConnect)
    }
}

// MARK: - Send methods

internal extension SignalClient {

    func sendOffer(offer: RTCSessionDescription) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.offer = offer.toPBType()
        }

        return sendRequest(r)
    }

    func sendAnswer(answer: RTCSessionDescription) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.answer = answer.toPBType()
        }

        return sendRequest(r)
    }

    func sendCandidate(candidate: RTCIceCandidate, target: Livekit_SignalTarget) -> Promise<Void> {
        log("target: \(target)")

        return Promise { () -> Livekit_SignalRequest in

            try Livekit_SignalRequest.with {
                $0.trickle = try Livekit_TrickleRequest.with {
                    $0.target = target
                    $0.candidateInit = try candidate.toLKType().toJsonString()
                }
            }

        }.then {
            self.sendRequest($0)
        }
    }

    func sendMuteTrack(trackSid: String, muted: Bool) -> Promise<Void> {
        log("trackSid: \(trackSid), muted: \(muted)")

        let r = Livekit_SignalRequest.with {
            $0.mute = Livekit_MuteTrackRequest.with {
                $0.sid = trackSid
                $0.muted = muted
            }
        }

        return sendRequest(r)
    }

    func sendAddTrack(cid: String,
                      name: String,
                      type: Livekit_TrackType,
                      source: Livekit_TrackSource = .unknown,
                      _ populator: (inout Livekit_AddTrackRequest) -> Void) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.addTrack = Livekit_AddTrackRequest.with {
                populator(&$0)
                $0.cid = cid
                $0.name = name
                $0.type = type
                $0.source = source
            }
        }

        return sendRequest(r)
    }

    func sendUpdateTrackSettings(sid: String,
                                 enabled: Bool,
                                 width: Int = 0,
                                 height: Int = 0) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.trackSetting = Livekit_UpdateTrackSettings.with {
                $0.trackSids = [sid]
                $0.disabled = !enabled
                $0.width = UInt32(width) // unlikely to overflow
                $0.height = UInt32(height) // unlikely to overflow
            }
        }

        return sendRequest(r)
    }

    func sendUpdateVideoLayers(trackSid: String,
                               layers: [Livekit_VideoLayer]) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.updateLayers = Livekit_UpdateVideoLayers.with {
                $0.trackSid = trackSid
                $0.layers = layers
            }
        }

        return sendRequest(r)
    }

    func sendUpdateSubscription(sid: String, subscribed: Bool) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.subscription = Livekit_UpdateSubscription.with {
                $0.trackSids = [sid]
                $0.subscribe = subscribed
            }
        }

        return sendRequest(r)
    }

    func sendUpdateSubscriptionPermission(allParticipants: Bool,
                                          trackPermissions: [ParticipantTrackPermission]) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.subscriptionPermission = Livekit_SubscriptionPermission.with {
                $0.allParticipants = allParticipants
                $0.trackPermissions = trackPermissions.map({ $0.toPBType() })
            }
        }

        return sendRequest(r)
    }

    func sendSyncState(answer: Livekit_SessionDescription,
                       subscription: Livekit_UpdateSubscription,
                       publishTracks: [Livekit_TrackPublishedResponse]?) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.syncState = Livekit_SyncState.with {
                $0.answer = answer
                $0.subscription = subscription
                $0.publishTracks = publishTracks ?? []
            }
        }

        return sendRequest(r)
    }

    func sendLeave() -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.leave = Livekit_LeaveRequest()
        }

        return sendRequest(r)
    }

    func sendSimulate(scenario: SimulateScenario) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.simulate = Livekit_SimulateScenario.with {
                if case .nodeFailure = scenario { $0.nodeFailure = true }
                if case .migration = scenario { $0.migration = true }
                if case .serverLeave = scenario { $0.serverLeave = true }
                if case .speakerUpdate(let secs) = scenario { $0.speakerUpdate = Int32(secs) }
            }
        }

        return sendRequest(r)
    }
}
