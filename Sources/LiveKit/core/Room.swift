//
// LiveKit
// https://livekit.io
//

import Foundation
import Network
import Promises
import WebRTC

// network path discovery updates multiple times, causing us to disconnect again
// using a timer interval to ignore changes that are happening too close to each other
let networkChangeIgnoreInterval = 3.0

public class Room: NSObject, MulticastDelegate {

    typealias DelegateType = RoomDelegate
    internal let delegates = NSHashTable<AnyObject>.weakObjects()

    public private(set) var sid: Sid?
    public private(set) var name: String?
    public private(set) var state: ConnectionState = .disconnected
    public private(set) var localParticipant: LocalParticipant?
    public private(set) var remoteParticipants = [Sid: RemoteParticipant]()
    public private(set) var activeSpeakers: [Participant] = []

    public let connectOptions: ConnectOptions
//    private let monitor: NWPathMonitor
    private let monitorQueue: DispatchQueue
    private var prevPath: NWPath?
    private var lastPathUpdate: TimeInterval = 0
    internal var engine: RTCEngine

    init(options: ConnectOptions, delegate: RoomDelegate) {
        self.connectOptions = options

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
        super.init()
        engine.add(delegate: self)
        add(delegate: delegate)
    }

    deinit {
        engine.remove(delegate: self)
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
        engine.signalClient.sendLeave()
        engine.close()
        handleDisconnect()
    }

    func reconnect() {
        if state != .connected && state != .reconnecting {
            return
        }
        state = .reconnecting
        engine.reconnect()
        notify { $0.isReconnecting(room: self) }
    }

    private func handleParticipantDisconnect(sid: Sid, participant: RemoteParticipant) {
        guard let participant = remoteParticipants.removeValue(forKey: sid) else {
            return
        }
        participant.tracks.values.forEach { publication in
            participant.unpublishTrack(sid: publication.sid)
        }

        notify { $0.participantDidDisconnect(room: self, participant: participant) }
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
        notify { $0.activeSpeakersDidChange(speakers: activeSpeakers, room: self) }
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
        notify { $0.activeSpeakersDidChange(speakers: activeSpeakers, room: self) }
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
        notify { $0.didDisconnect(room: self, error: nil) }
        // should be the only call from delegate, room is done
//        delegate = nil
    }
}

// MARK: - RTCEngineDelegate

extension Room: RTCEngineDelegate {

    func didUpdateSpeakersSignal(speakers: [Livekit_SpeakerInfo]) {
        onSignalSpeakersUpdate(speakers)
    }

    func didUpdateSpeakersEngine(speakers: [Livekit_SpeakerInfo]) {
        onEngineSpeakersUpdate(speakers)
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
        notify { $0.didConnect(room: self) }
    }

    func ICEDidReconnect() {
        state = .connected
        notify { $0.didReconnect(room: self) }
    }

    func didAddTrack(track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {
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
                notify { $0.participantDidConnect(room: self, participant: participant) }
            } else {
                participant.updateFromInfo(info: info)
            }
        }
    }

    func didReceive(userPacket: Livekit_UserPacket, kind _: Livekit_DataPacket.Kind) {
        guard let participant = remoteParticipants[userPacket.participantSid] else {
            logger.warning("could not find participant for data packet: \(userPacket.participantSid)")
            return
        }

        notify { $0.didReceive(data: userPacket.payload, participant: participant) }
        participant.notify { $0.didReceive(data: userPacket.payload, participant: participant) }
    }

    func remoteMuteDidChange(trackSid: String, muted: Bool) {
        if let track = localParticipant?.tracks[trackSid] as? LocalTrackPublication {
            track.setMuted(muted)
        }
    }

    func didDisconnect(reason: String, code: UInt16) {
        notify { $0.didDisconnect(room: self, error: nil) }
    }

    func didFailToConnect(error: Error) {
        notify { $0.didFailToConnect(room: self, error: error) }
    }
}
