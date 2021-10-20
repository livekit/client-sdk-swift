import Foundation
import Network
import Promises
import WebRTC

// network path discovery updates multiple times, causing us to disconnect again
// using a timer interval to ignore changes that are happening too close to each other
let networkChangeIgnoreInterval = 3.0

public class Room: MulticastDelegate<RoomDelegate> {

    public private(set) var sid: Sid?
    public private(set) var name: String?
    public private(set) var localParticipant: LocalParticipant?
    public private(set) var remoteParticipants = [Sid: RemoteParticipant]()
    public private(set) var activeSpeakers: [Participant] = []

    //    private let monitor: NWPathMonitor
    private let monitorQueue: DispatchQueue
    private var prevPath: NWPath?
    private var lastPathUpdate: TimeInterval = 0
    internal let engine: Engine
    public var state: ConnectionState {
        engine.connectionState
    }

    init(connectOptions: ConnectOptions, delegate: RoomDelegate?) {

        //        monitor = NWPathMonitor()
        monitorQueue = DispatchQueue(label: "networkMonitor", qos: .background)

        engine = Engine(connectOptions: connectOptions)

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
        super.init()
        engine.add(delegate: self)

        if let delegate = delegate {
            add(delegate: delegate)
        }
    }

    deinit {
        engine.remove(delegate: self)
    }

    @discardableResult
    func connect() -> Promise<Room> {
        logger.info("connecting to room")
        guard localParticipant == nil else {
            return Promise(EngineError.invalidState("localParticipant is not nil"))
        }

        //        monitor.start(queue: monitorQueue)
        return engine.connect().then {
            self
        }
    }

    public func disconnect() {
        engine.signalClient.sendLeave()
        engine.disconnect()
        handleDisconnect()
    }

    //    func reconnect(connectOptions: ConnectOptions? = nil) {
    //        if state != .connected && state != .reconnecting {
    //            return
    //        }
    //        state = .connecting(reconnecting: true)
    //        engine.reconnect(connectOptions: connectOptions)
    //        notify { $0.isReconnecting(room: self) }
    //    }

    private func handleParticipantDisconnect(sid: Sid, participant: RemoteParticipant) {
        guard let participant = remoteParticipants.removeValue(forKey: sid) else {
            return
        }
        participant.tracks.values.forEach { publication in
            participant.unpublishTrack(sid: publication.sid)
        }

        notify { $0.room(self, participantDidLeave: participant) }
    }

    private func getOrCreateRemoteParticipant(sid: Sid, info: Livekit_ParticipantInfo? = nil) -> RemoteParticipant {
        if let participant = remoteParticipants[sid] {
            return participant
        }
        let participant = RemoteParticipant(sid: sid, info: info)
        participant.room = self // wire up to room delegate calls
        remoteParticipants[sid] = participant
        return participant
    }

    private func onSignalSpeakersUpdate(_ speakers: [Livekit_SpeakerInfo]) {
        var lastSpeakers = activeSpeakers.reduce(into: [Sid: Participant]()) { $0[$1.sid] = $1 }
        for speaker in speakers {
            let p = speaker.sid == localParticipant?.sid ? localParticipant : remoteParticipants[speaker.sid]
            guard let p = p else {
                continue
            }

            p.audioLevel = speaker.level
            p.isSpeaking = speaker.active
            if speaker.active {
                lastSpeakers[speaker.sid] = p
            } else {
                lastSpeakers.removeValue(forKey: speaker.sid)
            }
        }

        let activeSpeakers = lastSpeakers.values.sorted(by: { $1.audioLevel > $0.audioLevel })
        self.activeSpeakers = activeSpeakers
        notify { $0.room(self, didUpdate: activeSpeakers)}
    }

    private func onEngineSpeakersUpdate(_ speakers: [Livekit_SpeakerInfo]) {
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
        notify { $0.room(self, didUpdate: activeSpeakers) }
    }

    private func handleDisconnect() {
        logger.info("disconnected from room: \(self.name ?? "")")
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
        notify { $0.room(self, didDisconnect: nil) }
    }
}

// MARK: - RTCEngineDelegate

extension Room: EngineDelegate {

    func engine(_ engine: Engine, didUpdateSignal speakers: [Livekit_SpeakerInfo]) {
        onSignalSpeakersUpdate(speakers)
    }

    func engine(_ engine: Engine, didUpdateEngine speakers: [Livekit_SpeakerInfo]) {
        onEngineSpeakersUpdate(speakers)
    }

    func engine(_ engine: Engine, didConnect isReconnect: Bool) {
        notify { $0.room(self, didConnect: isReconnect) }
    }

    func engineDidDisconnect(_ engine: Engine) {
        handleDisconnect()
    }

    func engine(_ engine: Engine, didUpdate connectionState: ConnectionState) {
        notify { $0.room(self, didUpdate: connectionState) }
    }

    func engine(_ engine: Engine, didReceive joinResponse: Livekit_JoinResponse) {
        logger.info("connected to room, server version: \(joinResponse.serverVersion)")

        sid = joinResponse.room.sid
        name = joinResponse.room.name

        if joinResponse.hasParticipant {
            localParticipant = LocalParticipant(fromInfo: joinResponse.participant, engine: engine, room: self)
        }
        if !joinResponse.otherParticipants.isEmpty {
            for otherParticipant in joinResponse.otherParticipants {
                _ = getOrCreateRemoteParticipant(sid: otherParticipant.sid, info: otherParticipant)
            }
        }
    }

    func engine(_ engine: Engine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {
        guard streams.count > 0 else {
            logger.error("received onTrack with no streams!")
            return
        }

        let unpacked = streams[0].streamId.unpack()
        let participantSid = unpacked.sid
        var trackSid = unpacked.trackId
        if trackSid == "" {
            trackSid = track.trackId
        }
        let participant = getOrCreateRemoteParticipant(sid: participantSid)

        logger.debug("added media track from: \(participantSid), sid: \(trackSid)")

        participant.addSubscribedMediaTrack(rtcTrack: track, sid: trackSid)
    }

    func engine(_ engine: Engine, didUpdate participants: [Livekit_ParticipantInfo]) {
        for info in participants {
            if info.sid == localParticipant?.sid {
                localParticipant?.updateFromInfo(info: info)
                continue
            }
            let isNewParticipant = remoteParticipants[info.sid] == nil
            let participant = getOrCreateRemoteParticipant(sid: info.sid, info: info)

            if info.state == .disconnected {
                handleParticipantDisconnect(sid: info.sid, participant: participant)
            } else if isNewParticipant {
                notify { $0.room(self, participantDidJoin: participant) }
            } else {
                participant.updateFromInfo(info: info)
            }
        }
    }

    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket) {
        guard let participant = remoteParticipants[userPacket.participantSid] else {
            logger.warning("could not find participant for data packet: \(userPacket.participantSid)")
            return
        }

        notify { $0.room(self, participant: participant, didReceive: userPacket.payload) }
        participant.notify { $0.participant(participant, didReceive: userPacket.payload) }
    }

    func engine(_ engine: Engine, didUpdateRemoteMute trackSid: String, muted: Bool) {
        if let track = localParticipant?.tracks[trackSid] as? LocalTrackPublication {
            track.setMuted(muted)
        }
    }

    func didDisconnect(reason: String, code: UInt16) {
        notify { $0.room(self, didDisconnect: nil) }
    }

    func engine(_ engine: Engine, didFailConnection error: Error) {
        notify { $0.room(self, didFailToConnect: error) }
    }
}
