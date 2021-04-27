//
//  File.swift
//
//
//  Created by Russell D'Sa on 11/7/20.
//

import Foundation
import Network
import Promises
import Starscream
import WebRTC

enum RoomError: Error {
    case missingRoomId(String)
}

let networkChangeIgnoreInterval = 15.0

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
    private let monitor: NWPathMonitor
    private let monitorQueue: DispatchQueue
    private var prevPath: NWPath?
    private var lastPathUpdate: TimeInterval = 0
    internal var engine: RTCEngine

    init(options: ConnectOptions) {
        connectOptions = options

        monitor = NWPathMonitor()
        monitorQueue = DispatchQueue(label: "networkMonitor", qos: .background)
        engine = RTCEngine(client: RTCClient())

        monitor.pathUpdateHandler = { path in
            if self.prevPath == nil || path.status != .satisfied {
                self.prevPath = path
                return
            }

            let currTime = Date().timeIntervalSince1970
            // ICE restarts are expensive, skip frequent changes
            if currTime - self.lastPathUpdate < networkChangeIgnoreInterval {
                logger.debug("skipping duplicate network update")
                return
            }
            // trigger reconnect
            if self.state == .connected {
                logger.info("network path changed, starting engine reconnect")
                self.engine.reconnect()
            }
            self.prevPath = path
            self.lastPathUpdate = currTime
        }

        engine.delegate = self
    }

    func connect() {
        guard localParticipant == nil else {
            return
        }

        monitor.start(queue: monitorQueue)
        engine.join(options: connectOptions)
    }

    public func disconnect() {
        engine.client.sendLeave()
        engine.close()
        handleDisconnect()
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

        if seenSids[localParticipant!.sid] == nil {
            localParticipant?.audioLevel = 0.0
            localParticipant?.isSpeaking = false
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
        let localP = localParticipant
        if localP != nil {
            for publication in localP!.tracks.values {
                guard let track = publication.track else {
                    continue
                }
                track.stop()
            }
        }

        do {
            try LiveKit.releaseAudioSession()
        } catch {
            logger.error("could not release audio session: \(error)")
        }
        remoteParticipants.removeAll()
        activeSpeakers.removeAll()
        monitor.cancel()
        delegate?.didDisconnect(room: self, error: nil)
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

    func didAddTrack(track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {
        guard streams.count > 0 else {
            logger.error("received onTrack with no streams!")
            return
        }

        let participantSid = streams[0].streamId
        let trackSid = track.trackId
        let participant = getOrCreateRemoteParticipant(sid: participantSid)

        logger.debug("added media track from: \(participantSid), sid: \(trackSid)")
        participant.addSubscribedMediaTrack(rtcTrack: track, sid: trackSid)
    }

    func didAddDataChannel(channel: RTCDataChannel) {
        var participantSid: Participant.Sid, trackSid: String, name: String
        (participantSid, trackSid, name) = channel.unpackedTrackLabel

        logger.debug("added data track from: \(participantSid), sid: \(trackSid)")
        let participant = getOrCreateRemoteParticipant(sid: participantSid)
        participant.addSubscribedDataTrack(rtcTrack: channel, sid: trackSid, name: name)
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
