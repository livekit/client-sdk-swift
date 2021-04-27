//
//  File.swift
//
//
//  Created by Russell D'Sa on 11/29/20.
//

import Foundation
import Promises
import Starscream
import WebRTC

enum RTCClientError: Error {
    case invalidRTCSdpType
    case socketNotConnected
    case socketError(String, UInt16)
    case socketDisconnected
}

class RTCClient {
    private(set) var isConnected: Bool = false
    private var socket: WebSocket?
    weak var delegate: RTCClientDelegate?
    private var reconnecting: Bool = false

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

    func join(options: ConnectOptions) {
        let url = options.url
        let token = options.accessToken

        var wsUrlString = "\(url)/rtc?access_token=\(token)"
        if options.reconnect != nil, options.reconnect! {
            wsUrlString += "&reconnect=1"
            reconnecting = true
        }
        logger.debug("connecting to url: \(wsUrlString)")
        var request = URLRequest(url: URL(string: wsUrlString)!)
        request.timeoutInterval = 5

        socket = WebSocket(request: request)
        socket!.delegate = self
        socket!.connect()
    }

    func sendOffer(offer: RTCSessionDescription) {
        logger.debug("sending offer")
        let sessionDescription = try! RTCClient.toProtoSessionDescription(sdp: offer)
        var req = Livekit_SignalRequest()
        req.offer = sessionDescription
        sendRequest(req: req)
    }

    func sendAnswer(answer: RTCSessionDescription) {
        logger.debug("sending answer")
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
            socket?.write(data: msg)
        } catch {
            logger.error("error sending signal message: \(error)")
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

    func handleSignalResponse(msg: Livekit_SignalResponse.OneOf_Message) {
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

    func close() {
        isConnected = false
        socket?.disconnect()
    }
}

extension RTCClient: WebSocketDelegate {
    func didReceive(event: WebSocketEvent, client _: WebSocket) {
        var sigResp: Livekit_SignalResponse?
        switch event {
        case let .text(string):
            let jsonData = string.data(using: .utf8)
            do {
                sigResp = try Livekit_SignalResponse(jsonUTF8Data: jsonData!)
            } catch {
                logger.error("error decoding JSON signal response: \(error)")
                return
            }

        case let .binary(data):
            do {
                sigResp = try Livekit_SignalResponse(contiguousBytes: data)
            } catch {
                logger.error("error decoding Proto signal response: \(error)")
                return
            }

        case let .error(error):
            logger.warning("websocket error: \(String(describing: error))")
            isConnected = false
            delegate?.onClose(reason: "error", code: 0)
            return

        case let .disconnected(reason, code):
            logger.debug("websocket disconnected: \(reason)")
            isConnected = false
            delegate?.onClose(reason: reason, code: code)
            return

        case .cancelled:
            isConnected = false
            return

        case .connected:
            if reconnecting {
                isConnected = true
                reconnecting = false
                delegate?.onReconnect()
            }
            return

        default:
            return
        }

        if let sigMsg = sigResp, let msg = sigMsg.message {
            switch msg {
            case let .join(joinMsg) where isConnected == false:
                isConnected = true
                delegate?.onJoin(info: joinMsg)
            default:
                handleSignalResponse(msg: msg)
            }
        }
    }
}
