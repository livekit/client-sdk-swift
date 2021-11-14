import Foundation
import Promises
import WebRTC

internal class SignalClient: MulticastDelegate<SignalClientDelegate> {

    // connection state of WebSocket
    private(set) var connectionState: ConnectionState = .disconnected()

    private lazy var urlSession = URLSession(configuration: .default,
                                             delegate: self,
                                             delegateQueue: OperationQueue())

    private var webSocket: URLSessionWebSocketTask?

    func connect(_ url: String,
                 _ token: String,
                 options: ConnectOptions? = nil,
                 reconnect: Bool = false) -> Promise<Void> {

        Promise<Void> { () -> Void in
            let rtcUrl = try Utils.buildUrl(url,
                                            token,
                                            options: options ,
                                            reconnect: reconnect)
            logger.debug("connecting with url: \(rtcUrl)")

            self.webSocket?.cancel()

            var request = URLRequest(url: rtcUrl)
            request.networkServiceType = .voip
            self.webSocket = self.urlSession.webSocketTask(with: request)
            self.webSocket!.resume() // Unexpectedly found nil while unwrapping an Optional values
            self.connectionState = .connecting(isReconnecting: reconnect)
        }.then {
            self.waitForWebSocketConnected()
        }
    }

    private func sendRequest(_ request: Livekit_SignalRequest) {

        guard case .connected = connectionState else {
            logger.error("could not send message, not connected")
            return
        }

        do {
            let msg = try request.serializedData()
            let message = URLSessionWebSocketTask.Message.data(msg)
            webSocket?.send(message) { error in
                if let error = error {
                    logger.error("could not send message: \(error)")
                }
            }
        } catch {
            logger.error("could not serialize data: \(error)")
        }
    }

    func close() {
        urlSession.invalidateAndCancel()
        webSocket?.cancel()
        webSocket = nil
        connectionState = .disconnected()
    }

    // handle errors after already connected
    private func handleError(_ reason: String) {
        notify { $0.signalClient(self, didClose: reason, code: 0) }
        close()
    }

    private func handleSignalResponse(msg: Livekit_SignalResponse.OneOf_Message) {

        guard case .connected = connectionState else {
            logger.error("not connected")
            return
        }

        do {
            switch msg {
            case let .join(joinResponse) :
                notify { $0.signalClient(self, didReceive: joinResponse) }

            case let .answer(sd):
                try notify { $0.signalClient(self, didReceiveAnswer: try sd.toRTCType()) }

            case let .offer(sd):
                try notify { $0.signalClient(self, didReceiveOffer: try sd.toRTCType()) }

            case let .trickle(trickle):
                let rtcCandidate = try RTCIceCandidate(fromJsonString: trickle.candidateInit)
                notify { $0.signalClient(self, didReceive: rtcCandidate, target: trickle.target) }

            case let .update(update):
                notify { $0.signalClient(self, didUpdate: update.participants) }

            case let .trackPublished(trackPublished):
                notify { $0.signalClient(self, didPublish: trackPublished) }

            case let .speakersChanged(speakers):
                notify { $0.signalClient(self, didUpdate: speakers.speakers) }

            case let .connectionQuality(quality):
                notify { $0.signalClient(self, didUpdate: quality.updates) }

            case let .mute(mute):
                notify { $0.signalClient(self, didUpdateRemoteMute: mute.sid, muted: mute.muted) }

            case .leave:
                notify { $0.signalClientDidLeave(self) }

            default:
                logger.warning("unsupported signal response type: \(msg)")
            }
        } catch {
            logger.error("could not handle signal response: \(error)")
        }
    }

    private func receiveNext() {
        guard let webSocket = webSocket else {
            logger.debug("webSocket is nil")
            return
        }
        webSocket.receive(completionHandler: handleWebsocketMessage)
    }

    private func handleWebsocketMessage(result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .failure(let error):
            // cancel connection on failure
            logger.error("could not receive websocket: \(error)")
            handleError(error.localizedDescription)
        case .success(let msg):
            var response: Livekit_SignalResponse?
            switch msg {
            case .data(let data):
                do {
                    response = try Livekit_SignalResponse(contiguousBytes: data)
                } catch {
                    logger.error("could not decode protobuf message: \(error)")
                    handleError(error.localizedDescription)
                }
            case .string(let text):
                do {
                    response = try Livekit_SignalResponse(jsonString: text)
                } catch {
                    logger.error("could not decode JSON message: \(error)")
                    handleError(error.localizedDescription)
                }
            default:
                return
            }

            if let sigResp = response, let msg = sigResp.message {
                handleSignalResponse(msg: msg)
            }

            // queue up the next read
            DispatchQueue.global(qos: .background).async {
                self.receiveNext()
            }
        }
    }

}

// MARK: Wait extension

extension SignalClient {

    func waitForWebSocketConnected() -> Promise<Void> {

        return Promise<Void> { fulfill, reject in
            // create temporary delegate
            var delegate: SignalClientDelegateClosures?
            delegate = SignalClientDelegateClosures(didConnect: { _, _ in
                // wait until connected
                fulfill(())
                delegate = nil
            }, didFailConnection: { _, error in
                reject(error)
                delegate = nil
            })
            // not required to clean up since weak reference
            self.add(delegate: delegate!)
        }
        // convert to a timed-promise
        .timeout(3)
    }

    func waitReceiveJoinResponse() -> Promise<Livekit_JoinResponse> {

        logger.debug("waiting for join response...")

        return Promise<Livekit_JoinResponse> { fulfill, _ in
            // create temporary delegate
            var delegate: SignalClientDelegateClosures?
            delegate = SignalClientDelegateClosures(didReceiveJoinResponse: { _, joinResponse in
                // wait until connected
                fulfill(joinResponse)
                delegate = nil
            })
            // not required to clean up since weak reference
            self.add(delegate: delegate!)
        }
        // convert to a timed-promise
        .timeout(3)
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
                                 disabled: Bool,
                                 width: Int = 0,
                                 height: Int = 0) {
        logger.debug("[SignalClient] Sending update track settings")

        let r = Livekit_SignalRequest.with {
            $0.trackSetting = Livekit_UpdateTrackSettings.with {
                $0.trackSids = [sid]
                $0.disabled = disabled
                $0.width = UInt32(width) // unlikely to overflow
                $0.height = UInt32(height) // unlikely to overflow
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

    func sendLeave() {
        logger.debug("[SignalClient] Sending leave")

        let r = Livekit_SignalRequest.with {
            $0.leave = Livekit_LeaveRequest()
        }

        sendRequest(r)
    }
}

// MARK: - URLSessionWebSocketDelegate

extension SignalClient: URLSessionWebSocketDelegate {

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {

        guard webSocketTask == webSocket else {
            return
        }

        var isReconnect = false
        if case .connecting(let reconnecting) = connectionState, reconnecting {
            isReconnect = true
        }

        notify { $0.signalClient(self, didConnect: isReconnect) }
        connectionState = .connected
        receiveNext()
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {

        guard webSocketTask == webSocket else {
            return
        }

        logger.debug("websocket disconnected")
        connectionState = .disconnected()
        notify { $0.signalClient(self, didClose: "", code: UInt16(closeCode.rawValue)) }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {

        guard task == webSocket else {
            return
        }

        var realError: Error
        if error != nil {
            realError = error!
        } else {
            realError = SignalClientError.socketError("could not connect", 0)
        }

        connectionState = .disconnected(error)
        notify { $0.signalClient(self, didFailConnection: realError) }
    }
}
