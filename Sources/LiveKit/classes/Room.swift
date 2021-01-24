//
//  File.swift
//  
//
//  Created by Russell D'Sa on 11/7/20.
//

import Foundation
import WebRTC
import Promises
import Starscream

enum RoomError: Error {
    case missingRoomId(String)
}

public class Room {
    public typealias Sid = String
    
    private var _name: String?
    public var name: String? {
        get {
            _name == nil ? sid : _name!
        }
        set(newName) {
            _name = newName
        }
    }
    
    public var delegate: RoomDelegate?
    
    public private(set) var sid: Room.Sid?
    public private(set) var state: RoomState = .disconnected
    public private(set) var localParticipant: LocalParticipant?
    public private(set) var remoteParticipants: Set<RemoteParticipant> = []
    
    private var connectOptions: ConnectOptions
    private var client: RTCClient
    private var engine: RTCEngine
    private var joinPromise: Promise<Room>?
    
    init(options: ConnectOptions) {
        _name = options.config.roomName
        connectOptions = options
        client = RTCClient()
        engine = RTCEngine(client: client)
        engine.delegate = self
    }
    
    func connect() throws -> Promise<Room> {
        guard let sid = sid else {
            throw RoomError.missingRoomId("Can't connect to a room without value for SID")
        }
        engine.join(roomId: sid, options: connectOptions)
        joinPromise = Promise<Room>.pending()
        return joinPromise!
    }
    
    static func join(options: ConnectOptions) -> Promise<Room> {
        let promise = Promise<Room>.pending()
//        var roomRequest = Livekit_Ro
//        roomRequest.room = options.config.roomId!
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
            let room = Room(options: options)
            // for now
            room.sid = options.config.roomId
            promise.fulfill(room)
        })
//        TwirpRpc.request(
//            connectOptions: options,
//            service: "RoomService",
//            method: "GetRoom",
//            data: roomRequest,
//            to: Livekit_RoomInfo.self).then { roomInfo in
//                let room = Room(options: options)
//                room.sid = roomInfo.sid
//                promise.fulfill(room)
//            }.catch { error in
//                print("Error: \(error)")
//                promise.reject(error)
//            }
        return promise
    }
    
    static func create(options: ConnectOptions) -> Promise<Room> {
        let promise = Promise<Room>.pending()
//        TwirpRpc.request(
//            connectOptions: options,
//            service: "RoomService",
//            method: "CreateRoom",
//            data: Livekit_CreateRoomRequest(),
//            to: Livekit_RoomInfo.self).then { roomInfo in
//                let room = Room(options: options)
//                room.sid = roomInfo.sid
//                promise.fulfill(room)
//            }.catch { error in
//                print("Error: \(error)")
//                promise.reject(error)
//            }
        return promise
    }
}

extension Room: RTCEngineDelegate {
    func didPublishLocalTrack(cid: String, track: Livekit_TrackInfo) {
        
    }
    
    func didJoin(response: Livekit_JoinResponse) {
        print("engine delegate --- did join")
        state = .connected
        if response.hasParticipant {
            localParticipant = LocalParticipant(fromInfo: response.participant)
        }
        if !response.otherParticipants.isEmpty {
            for otherParticipant in response.otherParticipants {
                remoteParticipants.insert(RemoteParticipant(info: otherParticipant))
            }
        }
        delegate?.didConnect(room: self)
        joinPromise?.fulfill(self)
    }
    
    func didAddTrack(track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {
        print("engine delegate --- did add media track")
        var participantSid: Participant.Sid, trackSid: Track.Sid
        (participantSid, trackSid) = track.unpackedTrackId
        
        var participant = remoteParticipants.first { $0.sid == participantSid }
        if participant == nil {
            participant = RemoteParticipant(sid: participantSid, name: nil)
        }
        
        do {
            try participant!.addSubscribedMediaTrack(rtcTrack: track, sid: trackSid)
        } catch {
            print(error)
        }
    }
    
    func didAddDataChannel(channel: RTCDataChannel) {
        print("engine delegate --- did add data channel")
        var participantSid: Participant.Sid, trackSid: Track.Sid, name: String
        (participantSid, trackSid, name) = channel.unpackedTrackLabel
        
        var participant = remoteParticipants.first { $0.sid == participantSid }
        if participant == nil {
            participant = RemoteParticipant(sid: participantSid, name: nil)
        }

        do {
            try participant!.addSubscribedDataTrack(rtcTrack: channel, sid: trackSid, name: name)
        } catch {
            print(error)
        }
    }
    
    func didUpdateParticipants(updates: [Livekit_ParticipantInfo]) {
        print("engine delegate --- did update participants")
        for participantInfo in updates {
            var participant = remoteParticipants.first(where: { $0.sid == participantInfo.sid })
            switch participantInfo.state {
            case .disconnected:
                guard participant != nil else {
                    break
                }
                do {
                    try participant?.unpublishTracks()
                    remoteParticipants.remove(participant!)
                    delegate?.participantDidDisconnect(room: self, participant: participant!)
                } catch {
                    print(error)
                }
            default:
                if participant != nil {
                    participant!.info = participantInfo
                } else {
                    participant = RemoteParticipant(info: participantInfo)
                    remoteParticipants.insert(participant!)
                    delegate?.participantDidConnect(room: self, participant: participant!)
                }
            }
        }
    }
    
    func didDisconnect(reason: String, code: UInt16) {
        var error: Error?
        if code != CloseCode.normal.rawValue {
            error = RTCClientError.socketError(reason, code)
        }
        delegate?.didDisconnect(room: self, error: error)
    }
    
    func didFailToConnect(error: Error) {
        delegate?.didFailToConnect(room: self, error: error)
    }
}
