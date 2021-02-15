//
//  File.swift
//  
//
//  Created by Russell D'Sa on 11/29/20.
//

import Foundation
import WebRTC
import Starscream
import Promises

enum RTCClientError: Error {
    case invalidRTCSdpType
    case socketNotConnected
    case socketError(String, UInt16)
    case socketDisconnected
}

class RTCClient {
    static let defaultIceServers = ["stun:stun.l.google.com:19302",
                                    "stun:stun1.l.google.com:19302",
                                    "stun:stun2.l.google.com:19302",
                                    "stun:stun3.l.google.com:19302",
                                    "stun:stun4.l.google.com:19302"]
    
    private(set) var isConnected: Bool = false
    private var socket: WebSocket?
    weak var delegate: RTCClientDelegate?
    
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
        let transportProtocol = options.isSecure ? "wss" : "ws"
        let host = options.host
        let token = options.accessToken
        
        let wsUrlString = "\(transportProtocol)://\(host)/rtc?access_token=\(token)"
        print("rtc client --- connecting to: \(wsUrlString)")
        var request = URLRequest(url: URL(string: wsUrlString)!)
        request.timeoutInterval = 5
        
        socket = WebSocket(request: request)
        socket!.delegate = self
        socket!.connect()
    }
    
    func sendOffer(offer: RTCSessionDescription) {
        let sessionDescription = try! RTCClient.toProtoSessionDescription(sdp: offer)
        print("rtc client --- sending offer: \(sessionDescription)")
        var req = Livekit_SignalRequest()
        req.offer = sessionDescription
        try! sendRequest(req: req)
    }
    
    func sendAnswer(answer: RTCSessionDescription) {
        let sessionDescription = try! RTCClient.toProtoSessionDescription(sdp: answer)
        print("rtc client --- sending answer: \(sessionDescription)")
        var req = Livekit_SignalRequest()
        req.answer = sessionDescription
        try! sendRequest(req: req)
    }
    
    func sendCandidate(candidate: RTCIceCandidate, target: Livekit_SignalTarget) {
        print("rtc client --- sending ice candidate: \(candidate)")
        let iceCandidate = IceCandidate(sdp: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
        let candidateData = try! JSONEncoder().encode(iceCandidate)
        var trickle = Livekit_TrickleRequest()
        trickle.candidateInit = String(data: candidateData, encoding: .utf8)!
        trickle.target = target
        
        var req = Livekit_SignalRequest()
        req.trickle = trickle
        try! sendRequest(req: req)
    }
    
    func sendMuteTrack(trackSid: String, muted: Bool) {
        print("rtc client --- sending mute")
        var muteReq = Livekit_MuteTrackRequest()
        muteReq.sid = trackSid
        muteReq.muted = muted
        
        var req = Livekit_SignalRequest()
        req.mute = muteReq
        try! sendRequest(req: req)
    }
    
    func sendAddTrack(cid: Track.Cid, name: String, type: Livekit_TrackType) throws {
        print("rtc client --- sending add track")
        var addTrackReq = Livekit_AddTrackRequest()
        addTrackReq.cid = cid as String
        addTrackReq.name = name
        addTrackReq.type = type
        
        var req = Livekit_SignalRequest()
        req.addTrack = addTrackReq
        try sendRequest(req: req)
    }
    
    func sendRequest(req: Livekit_SignalRequest) throws {
        if !isConnected {
            throw RTCClientError.socketNotConnected
        }
        do {
            let msg = try req.jsonString()
            socket?.write(string: msg)
        } catch {
            print("rtc client --- error sending request \(error)")
            throw error
        }
    }
    
    func handleSignalResponse(msg: Livekit_SignalResponse.OneOf_Message) {
        guard isConnected else {
            print("rtc client --- should never get in here when not connected", msg)
            return
        }
        switch msg {
        case .answer(let sd):
            let sdp = try! RTCClient.fromProtoSessionDescription(sd: sd)
            delegate?.onAnswer(sessionDescription: sdp)
            
        case .offer(let sd):
            let sdp = try! RTCClient.fromProtoSessionDescription(sd: sd)
            delegate?.onOffer(sessionDescription: sdp)
        
        case .trickle(let trickle):
            let iceCandidate: IceCandidate = try! JSONDecoder().decode(IceCandidate.self, from: trickle.candidateInit.data(using: .utf8)!)
            let rtcCandidate = RTCIceCandidate(sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid)
            delegate?.onTrickle(candidate: rtcCandidate, target: trickle.target)
        
        case .update(let update):
            delegate?.onParticipantUpdate(updates: update.participants)
            
        case .trackPublished(let trackPublished):
            delegate?.onLocalTrackPublished(trackPublished: trackPublished)
    
        default:
            print("rtc client --- unsupported signal response type", msg)
        }
    }
    
    func close() {
        isConnected = false
        socket?.disconnect()
    }
}

extension RTCClient: WebSocketDelegate {
    
    func didReceive(event: WebSocketEvent, client: WebSocket) {
        switch event {
        case .text(let string):
            let jsonData = string.data(using: .utf8)
            var sigResp: Livekit_SignalResponse?
            do {
                sigResp = try Livekit_SignalResponse(jsonUTF8Data: jsonData!)
            } catch {
                print("rtc client --- error decoding signal response: \(error)")
            }
            if let sigMsg = sigResp, let msg = sigMsg.message {
                switch msg {
                case .join(let joinMsg) where isConnected == false:
                    isConnected = true
                    delegate?.onJoin(info: joinMsg)
                default:
                    handleSignalResponse(msg: msg)
                }
            }
            
        case .error(let error):
            isConnected = false
            print("rtc client --- websocket error: \(error!)")
            
        case .disconnected(let reason, let code):
            isConnected = false
            print("rtc client --- websocket connection closed: \(reason)")
            delegate?.onClose(reason: reason, code: code)
            
        case .cancelled:
            print("rtc client --- socket canceled")
            isConnected = false
            
        default:
            break
        }
    }
    
}
