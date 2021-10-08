//
// LiveKit
// https://livekit.io
//

import Foundation
import Promises
import WebRTC

class SignalClient : NSObject {

    weak var delegate: SignalClientDelegate?

    private(set) var connectionState: ConnectionState = .disconnected

    private lazy var urlSession = URLSession(configuration: .default,
                                             delegate: self,
                                             delegateQueue: OperationQueue())

    private var webSocket: URLSessionWebSocketTask?

    deinit {
        urlSession.invalidateAndCancel()
    }

    func join(options: ConnectOptions, reconnect: Bool = false) throws {

        do {
            webSocket?.cancel()
            let rtcUrl = try options.buildUrl(reconnect: reconnect)
            logger.debug("connecting to url: \(rtcUrl)")
            connectionState = reconnect ? .reconnecting : .connecting
            webSocket = urlSession.webSocketTask(with: rtcUrl)
            webSocket!.resume()
        } catch let error {
            delegate?.onSignalError(error: error)
            throw error
        }
    }

    private func sendRequest(_ request: Livekit_SignalRequest) {

        guard connectionState == .connected else {
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
        connectionState = .disconnected
        webSocket?.cancel()
        webSocket = nil
    }
    
    // handle errors after already connected
    private func handleError(_ reason: String) {
        delegate?.onSignalClose(reason: reason, code: 0)
        close()
    }

    private func handleSignalResponse(msg: Livekit_SignalResponse.OneOf_Message) {

        guard connectionState == .connected else {
            logger.error("not connected")
            return
        }
        
        do {
            switch msg {
            case let .answer(sd):
                delegate?.onSignalAnswer(sessionDescription: try sd.toRTCType())

            case let .offer(sd):
                delegate?.onSignalOffer(sessionDescription: try sd.toRTCType())

            case let .trickle(trickle):
                let rtcCandidate = try RTCIceCandidate(fromJsonString: trickle.candidateInit)
                delegate?.onSignalTrickle(candidate: rtcCandidate, target: trickle.target)

            case let .update(update):
                delegate?.onSignalParticipantUpdate(updates: update.participants)

            case let .trackPublished(trackPublished):
                delegate?.onSignalLocalTrackPublished(trackPublished: trackPublished)

            case let .speakersChanged(speakers):
                delegate?.onSignalActiveSpeakersChanged(speakers: speakers.speakers)

            case let .mute(mute):
                delegate?.onSignalRemoteMuteChanged(trackSid: mute.sid, muted: mute.muted)

            case .leave:
                delegate?.onSignalLeave()

            default:
                logger.warning("unsupported signal response type: \(msg)")
            }
        } catch {
            logger.error("could not handle signal response: \(error)")
        }
    }
    
    private func receiveNext() {
        guard let webSocket = webSocket else {
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
            var sigResp: Livekit_SignalResponse? = nil
            switch msg {
            case .data(let data):
                do {
                    sigResp = try Livekit_SignalResponse(contiguousBytes: data)
                } catch {
                    logger.error("could not decode protobuf message: \(error)")
                    handleError(error.localizedDescription)
                }
            case .string(let text):
                do {
                    sigResp = try Livekit_SignalResponse(jsonString: text)
                } catch {
                    logger.error("could not decode JSON message: \(error)")
                    handleError(error.localizedDescription)
                }
            default:
                return
            }
            
            if let sigResp = sigResp, let msg = sigResp.message {
                switch msg {
                case .join(let joinMsg) where connectionState != .connected:
                    connectionState = .connected
                    delegate?.onSignalJoin(joinResponse: joinMsg)
                default:
                    handleSignalResponse(msg: msg)
                }
            }
            
            // queue up the next read
            DispatchQueue.global(qos: .background).async {
                self.receiveNext()
            }
        }
    }

}

//MARK: - Send methods
extension SignalClient {

    func sendOffer(offer: RTCSessionDescription) throws {
        logger.debug("Sending offer")

        let r = try Livekit_SignalRequest.with {
            $0.offer = try offer.toPBType()
        }

        sendRequest(r)
    }

    func sendAnswer(answer: RTCSessionDescription) throws {
        logger.debug("Sending answer")

        let r = try Livekit_SignalRequest.with {
            $0.answer = try answer.toPBType()
        }

        sendRequest(r)
    }

    func sendCandidate(candidate: RTCIceCandidate, target: Livekit_SignalTarget) throws {
        logger.debug("Sending ICE candidate")

        let r = try Livekit_SignalRequest.with {
            $0.trickle = try Livekit_TrickleRequest.with {
                $0.target = target
                $0.candidateInit = try candidate.toLKType().toJsonString()
            }
        }

        sendRequest(r)
    }

    func sendMuteTrack(trackSid: String, muted: Bool) {
        logger.debug("Sending mute for \(trackSid), muted: \(muted)")

        let r = Livekit_SignalRequest.with {
            $0.mute = Livekit_MuteTrackRequest.with {
                $0.sid = trackSid
                $0.muted = muted
            }
        }

        sendRequest(r)
    }

    func sendAddTrack(cid: String, name: String, type: Livekit_TrackType,
                      dimensions: Dimensions? = nil) {
        logger.debug("Sending add track request")

        let r = Livekit_SignalRequest.with {
            $0.addTrack = Livekit_AddTrackRequest.with {
                $0.cid = cid
                $0.name = name
                $0.type = type
                if let dimensions = dimensions {
                    $0.width = UInt32(dimensions.width)
                    $0.height = UInt32(dimensions.height)
                }
            }
        }

        sendRequest(r)
    }

    func sendUpdateTrackSettings(sid: String, disabled: Bool, videoQuality: Livekit_VideoQuality) {
        logger.debug("Sending update track settings")

        let r = Livekit_SignalRequest.with {
            $0.trackSetting = Livekit_UpdateTrackSettings.with {
                $0.trackSids = [sid]
                $0.disabled = disabled
                $0.quality = videoQuality
            }
        }


        sendRequest(r)
    }

    func sendUpdateSubscription(sid: String, subscribed: Bool, videoQuality: Livekit_VideoQuality) {
        logger.debug("Sending update subscription")

        let r = Livekit_SignalRequest.with {
            $0.subscription = Livekit_UpdateSubscription.with {
                $0.trackSids = [sid]
                $0.subscribe = subscribed
            }
        }

        sendRequest(r)
    }

    func sendLeave() {
        logger.debug("Sending leave")

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

        if connectionState == .reconnecting {
            delegate?.onSignalReconnect()
        }

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
        connectionState = .disconnected
        delegate?.onSignalClose(reason: "", code: UInt16(closeCode.rawValue))
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
        delegate?.onSignalError(error: realError)
    }
}
