//
//  File.swift
//
//
//  Created by Russell D'Sa on 11/7/20.
//

import Foundation
import Network
import Promises
import WebRTC

enum RoomError: Error {
    case missingRoomId(String)
    case invalidURL(String)
    case protocolError(String)
}

// network path discovery updates multiple times, causing us to disconnect again
// using a timer interval to ignore changes that are happening too close to each other
let networkChangeIgnoreInterval = 3.0

public class Room {
    public typealias Sid = String

    public var delegate: RoomDelegate?

    public private(set) var sid: Room.Sid?
    public private(set) var name: String?
    public private(set) var state: RoomState = .disconnected
    public private(set) var localParticipant: LocalParticipant?
    public private(set) var remoteParticipants = [Participant.Sid: RemoteParticipant]()
    public private(set) var activeSpeakers: [Participant] = []

    private var connectOptions: ConnectOptions
//    private let monitor: NWPathMonitor
    private let monitorQueue: DispatchQueue
    private var prevPath: NWPath?
    private var lastPathUpdate: TimeInterval = 0
    internal var engine: RTCEngine

    init(options: ConnectOptions) {
        connectOptions = options

//        monitor = NWPathMonitor()
        monitorQueue = DispatchQueue(label: "networkMonitor", qos: .background)
        engine = RTCEngine(client: SignalClient())

//        monitor.pathUpdateHandler = { path in
//            logger.debug("network path update: \(path.availableInterfaces), \(path.status)")
//            if self.prevPath == nil || path.status != .satisfied {
//                self.prevPath = path
//                return
//            }
//
//            // TODO: Use debounce fnc instead
//            // In iOS 14.4, this update is sent multiple times during a connection change
//            // ICE restarts are expensive and error prone (due to renegotiation)
//            // We'll ignore frequent updates
//            let currTime = Date().timeIntervalSince1970
//            if currTime - self.lastPathUpdate < networkChangeIgnoreInterval {
//                logger.debug("skipping duplicate network update")
//                return
//            }
//            // trigger reconnect
//            if self.state != .disconnected {
//                logger.info("network path changed, starting engine reconnect")
//                self.reconnect()
//            }
//            self.prevPath = path
//            self.lastPathUpdate = currTime
//        }

        engine.delegate = self
    }

    func connect() {
        logger.info("connecting to room")
        guard localParticipant == nil else {
            return
        }

        state = .connecting
//        monitor.start(queue: monitorQueue)
        engine.join(options: connectOptions)
    }

    public func disconnect() {
        engine.client.sendLeave()
        engine.close()
        handleDisconnect()
    }

    func reconnect() {
        if state != .connected && state != .reconnecting {
            return
        }
        state = .reconnecting
        engine.reconnect()
        delegate?.isReconnecting(room: self)
    }

    private func handleParticipantDisconnect(sid: Participant.Sid, participant: RemoteParticipant) {
        guard let participant = remoteParticipants.removeValue(forKey: sid) else {
            return
        }
        participant.tracks.values.forEach { publication in
            participant.unpublishTrack(sid: publication.sid)
        }
        delegate?.participantDidDisconnect(room: self, participant: participant)
    }

    private func getOrCreateRemoteParticipant(sid: Participant.Sid, info: Livekit_ParticipantInfo? = nil) -> RemoteParticipant {
        if let participant = remoteParticipants[sid] {
            return participant
        }
        let participant = RemoteParticipant(sid: sid, info: info)
        participant.room = self // wire up to room delegate calls
        remoteParticipants[sid] = participant
        return participant
    }

    private func handleSpeakerUpdate(speakers: [Livekit_SpeakerInfo]) {
        var activeSpeakers: [Participant] = []
        var seenSids = [String: Bool]()
        for speaker in speakers {
            seenSids[speaker.sid] = true
            if speaker.sid == localParticipant?.sid {
                localParticipant?.audioLevel = speaker.level
                localParticipant?.isSpeaking = true
                activeSpeakers.append(localParticipant!)
            } else {
                if let participant = remoteParticipants[speaker.sid] {
                    participant.audioLevel = speaker.level
                    participant.isSpeaking = true
                    activeSpeakers.append(participant)
                }
            }
        }

        if let localParticipant = localParticipant, seenSids[localParticipant.sid] == nil {
            localParticipant.audioLevel = 0.0
            localParticipant.isSpeaking = false
        }
        for participant in remoteParticipants.values {
            if seenSids[participant.sid] == nil {
                participant.audioLevel = 0.0
                participant.isSpeaking = false
            }
        }
        self.activeSpeakers = activeSpeakers
        delegate?.activeSpeakersDidChange(speakers: activeSpeakers, room: self)
    }

    private func handleDisconnect() {
        if state == .disconnected {
            // only allow cleanup to be completed once
            return
        }
        logger.info("disconnected from room: \(self.name ?? "")")
        state = .disconnected
        // stop any tracks && release audio session
        for participant in remoteParticipants.values {
            for publication in participant.tracks.values {
                guard let track = publication.track else {
                    continue
                }
                track.stop()
            }
        }
        if let localParticipant = localParticipant {
            for publication in localParticipant.tracks.values {
                guard let track = publication.track else {
                    continue
                }
                track.stop()
            }
        }

        remoteParticipants.removeAll()
        activeSpeakers.removeAll()
//        monitor.cancel()
        delegate?.didDisconnect(room: self, error: nil)
        // should be the only call from delegate, room is done
        delegate = nil
    }
}

extension Room: RTCEngineDelegate {
    func didUpdateSpeakers(speakers: [Livekit_SpeakerInfo]) {
        handleSpeakerUpdate(speakers: speakers)
    }

    func didDisconnect() {
        handleDisconnect()
    }

    func didJoin(response: Livekit_JoinResponse) {
        logger.info("connected to room, server version: \(response.serverVersion)")

        sid = response.room.sid
        name = response.room.name

        if response.hasParticipant {
            localParticipant = LocalParticipant(fromInfo: response.participant, engine: engine, room: self)
        }
        if !response.otherParticipants.isEmpty {
            for otherParticipant in response.otherParticipants {
                _ = getOrCreateRemoteParticipant(sid: otherParticipant.sid, info: otherParticipant)
            }
        }
    }

    func ICEDidConnect() {
        state = .connected
        delegate?.didConnect(room: self)
    }

    func ICEDidReconnect() {
        state = .connected
        delegate?.didReconnect(room: self)
    }

    func didAddTrack(track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {
        guard streams.count > 0 else {
            logger.error("received onTrack with no streams!")
            return
        }
        
        let unpacked = unPackStreamId(streams[0].streamId)
        let participantSid = unpacked.participantId
        var trackSid = unpacked.trackId
        if trackSid == "" {
            trackSid = track.trackId
        }
        let participant = getOrCreateRemoteParticipant(sid: participantSid)
        
        logger.debug("added media track from: \(participantSid), sid: \(trackSid)")
    
        DispatchQueue.global(qos: .background).async {
            // ensure audio session is configured
            if track.kind == "audio" {
                if !LiveKit.audioConfigured {
                    LiveKit.configureAudioSession()
                }
            }
            participant.addSubscribedMediaTrack(rtcTrack: track, sid: trackSid)
        }
    }

    func didUpdateParticipants(updates: [Livekit_ParticipantInfo]) {
        for info in updates {
            if info.sid == localParticipant?.sid {
                localParticipant?.updateFromInfo(info: info)
                continue
            }
            let isNewParticipant = remoteParticipants[info.sid] == nil
            let participant = getOrCreateRemoteParticipant(sid: info.sid, info: info)

            if info.state == .disconnected {
                handleParticipantDisconnect(sid: info.sid, participant: participant)
            } else if isNewParticipant {
                delegate?.participantDidConnect(room: self, participant: participant)
            } else {
                participant.updateFromInfo(info: info)
            }
        }
    }

    func didReceive(packet: Livekit_UserPacket, kind _: Livekit_DataPacket.Kind) {
        guard let participant = remoteParticipants[packet.participantSid] else {
            logger.warning("could not find participant for data packet: \(packet.participantSid)")
            return
        }

        delegate?.didReceive(data: packet.payload, participant: participant)
        participant.delegate?.didReceive(data: packet.payload, participant: participant)
    }

    func remoteMuteDidChange(trackSid: String, muted: Bool) {
        if let track = localParticipant?.tracks[trackSid] as? LocalTrackPublication {
            track.setMuted(muted)
        }
    }

    func didDisconnect(reason: String, code: UInt16) {
        delegate?.didDisconnect(room: self, error: nil)
    }

    func didFailToConnect(error: Error) {
        delegate?.didFailToConnect(room: self, error: error)
    }
}

func unPackStreamId(_ streamId: String) -> (participantId: String, trackId: String) {
    let parts = streamId.split(separator: "|")
    if parts.count == 2 {
        return (String(parts[0]), String(parts[1]))
    }
    return (streamId, "")
}
