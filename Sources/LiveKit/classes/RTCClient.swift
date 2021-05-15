//
//  File.swift
//
//
//  Created by Russell D'Sa on 11/29/20.
//

import Foundation
import Promises
import WebRTC

enum RTCClientError: Error {
    case invalidRTCSdpType
    case socketNotConnected
    case socketError(String, UInt16)
    case socketDisconnected
}

let PROTOCOL_VERSION = 2

class RTCClient : NSObject {
    private(set) var isConnected: Bool = false
    weak var delegate: RTCClientDelegate?
    private var reconnecting: Bool = false
    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?

    static func fromProtoSessionDescription(sd: Livekit_SessionDescription) throws -> RTCSessionDescription {
        var rtcSdpType: RTCSdpType
        switch sd.type {
        case "answer":
            rtcSdpType = .answer
        case "offer":
            rtcSdpType = .offer
        case "pranswer":
            rtcSdpType = .prAnswer
        default:
            throw RTCClientError.invalidRTCSdpType
        }
        return RTCSessionDescription(type: rtcSdpType, sdp: sd.sdp)
    }

    static func toProtoSessionDescription(sdp: RTCSessionDescription) throws -> Livekit_SessionDescription {
        var sessionDescription = Livekit_SessionDescription()
        sessionDescription.sdp = sdp.sdp
        switch sdp.type {
        case .answer:
            sessionDescription.type = "answer"
        case .offer:
            sessionDescription.type = "offer"
        case .prAnswer:
            sessionDescription.type = "pranswer"
        default:
            throw RTCClientError.invalidRTCSdpType
        }
        return sessionDescription
    }
    
    override init() {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
    }

    func join(options: ConnectOptions) {
        let url = options.url
        let token = options.accessToken

        var wsUrlString = "\(url)/rtc?access_token=\(token)&protocol=\(PROTOCOL_VERSION)"
        if options.reconnect != nil, options.reconnect! {
            wsUrlString += "&reconnect=1"
            reconnecting = true
        }
        
        let existing = webSocket
        
        logger.debug("connecting to url: \(wsUrlString)")
        webSocket = urlSession!.webSocketTask(with: URL(string: wsUrlString)!)
        webSocket?.resume()

        existing?.cancel()
    }

    func sendOffer(offer: RTCSessionDescription) {
        logger.debug("sending offer")
        let sessionDescription = try! RTCClient.toProtoSessionDescription(sdp: offer)
        var req = Livekit_SignalRequest()
        req.offer = sessionDescription
        sendRequest(req: req)
    }

    func sendAnswer(answer: RTCSessionDescription) {
        let sessionDescription = try! RTCClient.toProtoSessionDescription(sdp: answer)
        var req = Livekit_SignalRequest()
        req.answer = sessionDescription
        sendRequest(req: req)
    }

    func sendCandidate(candidate: RTCIceCandidate, target: Livekit_SignalTarget) {
        let iceCandidate = IceCandidate(sdp: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
        let candidateData = try! JSONEncoder().encode(iceCandidate)
        var trickle = Livekit_TrickleRequest()
        trickle.candidateInit = String(data: candidateData, encoding: .utf8)!
        trickle.target = target

        var req = Livekit_SignalRequest()
        req.trickle = trickle
        sendRequest(req: req)
    }

    func sendMuteTrack(trackSid: String, muted: Bool) {
        logger.debug("sending mute for \(trackSid), muted: \(muted)")
        var muteReq = Livekit_MuteTrackRequest()
        muteReq.sid = trackSid
        muteReq.muted = muted

        var req = Livekit_SignalRequest()
        req.mute = muteReq
        sendRequest(req: req)
    }

    func sendAddTrack(cid: String, name: String, type: Livekit_TrackType) {
        var addTrackReq = Livekit_AddTrackRequest()
        addTrackReq.cid = cid as String
        addTrackReq.name = name
        addTrackReq.type = type

        var req = Livekit_SignalRequest()
        req.addTrack = addTrackReq
        sendRequest(req: req)
    }

    func sendRequest(req: Livekit_SignalRequest) {
        if !isConnected {
            logger.error("could not send message, not connected")
        }
        do {
            let msg = try req.serializedData()
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

    func sendUpdateTrackSettings(sid: String, disabled: Bool, videoQuality: Livekit_VideoQuality) {
        var update = Livekit_UpdateTrackSettings()
        update.trackSids = [sid]
        update.disabled = disabled
        update.quality = videoQuality

        var req = Livekit_SignalRequest()
        req.trackSetting = update
        sendRequest(req: req)
    }

    func sendUpdateSubscription(sid: String, subscribed: Bool, videoQuality: Livekit_VideoQuality) {
        var sub = Livekit_UpdateSubscription()
        sub.trackSids = [sid]
        sub.subscribe = subscribed
        sub.quality = videoQuality

        var req = Livekit_SignalRequest()
        req.subscription = sub
        sendRequest(req: req)
    }

    func sendLeave() {
        var req = Livekit_SignalRequest()
        req.leave = Livekit_LeaveRequest()
        sendRequest(req: req)
    }
    
    func close() {
        isConnected = false
        webSocket?.cancel()
        webSocket = nil
    }
    
    // handle errors after already connected
    private func handleError(_ reason: String) {
        delegate?.onClose(reason: reason, code: 0)
        close()
    }

    private func handleSignalResponse(msg: Livekit_SignalResponse.OneOf_Message) {
        guard isConnected else {
            return
        }
        switch msg {
        case let .answer(sd):
            let sdp = try! RTCClient.fromProtoSessionDescription(sd: sd)
            delegate?.onAnswer(sessionDescription: sdp)

        case let .offer(sd):
            let sdp = try! RTCClient.fromProtoSessionDescription(sd: sd)
            delegate?.onOffer(sessionDescription: sdp)

        case let .trickle(trickle):
            let iceCandidate: IceCandidate = try! JSONDecoder().decode(IceCandidate.self, from: trickle.candidateInit.data(using: .utf8)!)
            let rtcCandidate = RTCIceCandidate(sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid)
            delegate?.onTrickle(candidate: rtcCandidate, target: trickle.target)

        case let .update(update):
            delegate?.onParticipantUpdate(updates: update.participants)

        case let .trackPublished(trackPublished):
            delegate?.onLocalTrackPublished(trackPublished: trackPublished)

        case let .speaker(speakerUpdate):
            delegate?.onActiveSpeakersChanged(speakers: speakerUpdate.speakers)

        case .leave:
            delegate?.onLeave()

        default:
            logger.warning("unsupported signal response type: \(msg)")
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
                case let .join(joinMsg) where isConnected == false:
                    isConnected = true
                    delegate?.onJoin(info: joinMsg)
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

extension RTCClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask == webSocket else {
            return
        }
        if reconnecting {
            isConnected = true
            reconnecting = false
            delegate?.onReconnect()
        }
        
        receiveNext()
    }
       
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask == webSocket else {
            return
        }
        logger.debug("websocket disconnected")
        isConnected = false
        delegate?.onClose(reason: "", code: UInt16(closeCode.rawValue))
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task == webSocket else {
            return
        }
        
        var realError: Error
        if error != nil {
            realError = error!
        } else {
            realError = RTCClientError.socketError("could not connect", 0)
        }
        delegate?.onError(error: realError)
    }
}
