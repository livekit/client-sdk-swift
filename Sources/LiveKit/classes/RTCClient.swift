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
    var delegate: RTCClientDelegate?
    
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
    
    func join(roomId: String, options: ConnectOptions) {
        let transportProtocol = options.config.isSecure ? "wss" : "ws"
        let host = options.config.host
        let port = options.config.rtcPort
        let token = options.config.accessToken
        
        let wsUrlString = "\(transportProtocol)://\(host):\(port)/rtc?access_token=\(token)"
        var request = URLRequest(url: URL(string: wsUrlString)!)
        request.timeoutInterval = 5
        
        socket = WebSocket(request: request)
        socket!.delegate = self
        socket!.connect()
    }
    
    func close() {
        isConnected = false
        socket?.disconnect()
    }
    
    func sendOffer(sdp: RTCSessionDescription) {
        let sessionDescription = try! RTCClient.toProtoSessionDescription(sdp: sdp)
        print("Sending offer: \(sessionDescription)")
        var req = Livekit_SignalRequest()
        req.offer = sessionDescription
        try! sendRequest(req: req)
    }
    
    func sendNegotiate(sdp: RTCSessionDescription) {
        let sessionDescription = try! RTCClient.toProtoSessionDescription(sdp: sdp)
        print("Sending negotiate: \(sessionDescription)")
        var req = Livekit_SignalRequest()
        req.negotiate = sessionDescription

        try! sendRequest(req: req)
    }
    
    func sendCandidate(candidate: RTCIceCandidate) {
        print("Sending ice candidate: \(candidate)")
        let iceCandidate = IceCandidate(sdp: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
        let candidateData = try! JSONEncoder().encode(iceCandidate)
        var trickle = Livekit_Trickle()
        trickle.candidateInit = String(data: candidateData, encoding: .utf8)!
        var req = Livekit_SignalRequest()
        req.trickle = trickle
        
        try! sendRequest(req: req)
    }
    
    func sendRequest(req: Livekit_SignalRequest) throws {
        if !isConnected {
            throw RTCClientError.socketNotConnected
        }
        do {
            let msg = try req.jsonString()
            socket?.write(string: msg)
        } catch {
            throw error
        }
    }
    
    func handleSignalResponse(msg: Livekit_SignalResponse.OneOf_Message) {
        switch msg {
        case .answer(let sd):
            let sdp = try! RTCClient.fromProtoSessionDescription(sd: sd)
            delegate?.onAnswer(sessionDescription: sdp)
        case .negotiate(let sd):
            let sdp = try! RTCClient.fromProtoSessionDescription(sd: sd)
            delegate?.onNegotiate(sessionDescription: sdp)
        case .trickle(let trickle):
            let iceCandidate: IceCandidate = try! JSONDecoder().decode(IceCandidate.self, from: trickle.candidateInit.data(using: .utf8)!)
            delegate?.onTrickle(candidate: RTCIceCandidate(sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid))
        case .update(let update):
            delegate?.onParticipantUpdate(updates: update.participants)
        default:
            break
        }
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
                print("Error decoding signal response: \(error)")
            }
            if let sigMsg = sigResp, let msg = sigMsg.message {
                switch msg {
                case .join(let joinMsg):
                    isConnected = true
                    delegate?.onJoin(info: joinMsg)
                default:
                    handleSignalResponse(msg: msg)
                }
            }
        case .error(let error):
            isConnected = false
            print("Websocket error: \(error!)")
        case .disconnected(let reason, let code):
            isConnected = false
            print("Websocket connection closed: \(reason)")
            delegate?.onClose(reason: reason, code: code)
        case .cancelled:
            isConnected = false
        default:
            break
        }
    }
    
}
