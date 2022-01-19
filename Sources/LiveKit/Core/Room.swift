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
    //    private let monitorQueue: DispatchQueue
    private var prevPath: NWPath?
    private var lastPathUpdate: TimeInterval = 0

    // Reference to Engine
    internal lazy var engine = Engine(room: self)

    internal private(set) var connectOptions: ConnectOptions?
    internal private(set) var roomOptions: RoomOptions?

    // expose engine's connectionState
    public var state: ConnectionState {
        engine.connectionState
    }

    public var url: String? {
        engine.url
    }

    public var token: String? {
        engine.token
    }

    public init(delegate: RoomDelegate? = nil,
                connectOptions: ConnectOptions? = nil,
                roomOptions: RoomOptions? = nil) {

        self.connectOptions = connectOptions
        self.roomOptions = roomOptions
        super.init()

        if let delegate = delegate {
            add(delegate: delegate)
        }

        // monitor = NWPathMonitor()
        //        monitorQueue = DispatchQueue(label: "networkMonitor", qos: .background)

        //        monitor.pathUpdateHandler = { path in
        //            log("network path update: \(path.availableInterfaces), \(path.status)")
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
        //                log("skipping duplicate network update")
        //                return
        //            }
        //            // trigger reconnect
        //            if self.state != .disconnected {
        //                log("network path changed, starting engine reconnect", .info)
        //                self.reconnect()
        //            }
        //            self.prevPath = path
        //            self.lastPathUpdate = currTime
        //        }

    }

    deinit {
        // not really required to remove delegate since it's weak
        engine.remove(delegate: self)
    }

    @discardableResult
    public func connect(_ url: String,
                        _ token: String,
                        connectOptions: ConnectOptions? = nil,
                        roomOptions: RoomOptions? = nil) -> Promise<Room> {

        // update options if specified
        self.connectOptions = connectOptions ?? self.connectOptions
        self.roomOptions = roomOptions ?? self.roomOptions

        log("connecting to room", .info)
        guard localParticipant == nil else {
            return Promise(EngineError.state(message: "localParticipant is not nil"))
        }

        // monitor.start(queue: monitorQueue)
        return engine.connect(url, token).then(on: .sdk) { self }
    }

    @discardableResult
    public func disconnect() -> Promise<Void> {
        engine.signalClient.sendLeave()
        engine.disconnect()
        return handleDisconnect()
    }

    //    func reconnect(connectOptions: ConnectOptions? = nil) {
    //        if state != .connected && state != .reconnecting {
    //            return
    //        }
    //        state = .connecting(reconnecting: true)
    //        engine.reconnect(connectOptions: connectOptions)
    //        notify { $0.isReconnecting(room: self) }
    //    }

    private func getOrCreateRemoteParticipant(sid: Sid, info: Livekit_ParticipantInfo? = nil) -> RemoteParticipant {
        if let participant = remoteParticipants[sid] {
            return participant
        }
        let participant = RemoteParticipant(sid: sid, info: info, room: self)
        remoteParticipants[sid] = participant
        return participant
    }

    private func onParticipantDisconnect(sid: Sid, participant: RemoteParticipant) -> Promise<Void> {

        guard let participant = remoteParticipants.removeValue(forKey: sid) else {
            return Promise(EngineError.state(message: "Participant not found for \(sid)"))
        }

        // create array of unpublish promises
        let promises = participant.tracks.values
            .compactMap { $0 as? RemoteTrackPublication }
            .map { participant.unpublish(publication: $0) }

        return all(on: .sdk, promises).then(on: .sdk) { (_) -> Void in
            self.notify { $0.room(self, participantDidLeave: participant) }
        }
    }

    private func onSignalSpeakersUpdate(_ speakers: [Livekit_SpeakerInfo]) {
        var lastSpeakers = activeSpeakers.reduce(into: [Sid: Participant]()) { $0[$1.sid] = $1 }
        for speaker in speakers {

            guard let participant = speaker.sid == localParticipant?.sid ? localParticipant : remoteParticipants[speaker.sid] else {
                continue
            }

            participant.audioLevel = speaker.level
            participant.isSpeaking = speaker.active
            if speaker.active {
                lastSpeakers[speaker.sid] = participant
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
            if let localParticipant = localParticipant,
               speaker.sid == localParticipant.sid {
                localParticipant.audioLevel = speaker.level
                localParticipant.isSpeaking = true
                activeSpeakers.append(localParticipant)
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

    private func onConnectionQualityUpdate(_ connectionQuality: [Livekit_ConnectionQualityInfo]) {

        for entry in connectionQuality {
            if let localParticipant = localParticipant,
               entry.participantSid == localParticipant.sid {
                // update for LocalParticipant
                localParticipant.connectionQuality = entry.quality.toLKType()
            } else if let participant = remoteParticipants[entry.participantSid] {
                // udpate for RemoteParticipant
                participant.connectionQuality = entry.quality.toLKType()
            }
        }
    }

    private func onSubscribedQualitiesUpdate(trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) {
        localParticipant?.onSubscribedQualitiesUpdate(trackSid: trackSid, subscribedQualities: subscribedQualities)
    }

    private func onSubscriptionPermissionUpdate(permissionUpdate: Livekit_SubscriptionPermissionUpdate) {
        guard let participant = remoteParticipants[permissionUpdate.participantSid],
              let publication = participant.getTrackPublication(sid: permissionUpdate.trackSid) else {
            return
        }

        publication.subscriptionAllowed = permissionUpdate.allowed
    }

    private func handleDisconnect() -> Promise<Void> {
        log("disconnected from room: \(self.name ?? "")", .info)
        // stop any tracks && release audio session

        var promises = [Promise<Void>]()

        for participant in remoteParticipants.values {
            for publication in participant.tracks.values {
                guard let track = publication.track else { continue }
                promises.append(track.stop())
            }
        }

        if let localParticipant = localParticipant {
            for publication in localParticipant.tracks.values {
                guard let track = publication.track else { continue }
                promises.append(track.stop())
            }
        }

        return all(on: .sdk, promises).then(on: .sdk) { (_) -> Void in
            self.remoteParticipants.removeAll()
            self.activeSpeakers.removeAll()
            // monitor.cancel()
            self.notify { $0.room(self, didDisconnect: nil) }
        }
    }
}

// MARK: - RTCEngineDelegate

extension Room: EngineDelegate {

    func engine(_ engine: Engine, didUpdate dataChannel: RTCDataChannel, state: RTCDataChannelState) {}

    func engine(_ engine: Engine, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo]) {
        onConnectionQualityUpdate(connectionQuality)
    }

    func engine(_ engine: Engine, didUpdate trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) {
        onSubscribedQualitiesUpdate(trackSid: trackSid, subscribedQualities: subscribedQualities)
    }

    func engine(_ engine: Engine, didUpdate subscriptionPermission: Livekit_SubscriptionPermissionUpdate) {
        onSubscriptionPermissionUpdate(permissionUpdate: subscriptionPermission)
    }

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
        _ = handleDisconnect()
    }

    func engine(_ engine: Engine, didUpdate connectionState: ConnectionState) {
        notify { $0.room(self, didUpdate: connectionState) }
    }

    func engine(_ engine: Engine, didReceive joinResponse: Livekit_JoinResponse) {
        log("connected to room, server version: \(joinResponse.serverVersion)", .info)

        sid = joinResponse.room.sid
        name = joinResponse.room.name

        if joinResponse.hasParticipant {
            localParticipant = LocalParticipant(from: joinResponse.participant, room: self)
        }
        if !joinResponse.otherParticipants.isEmpty {
            for otherParticipant in joinResponse.otherParticipants {
                _ = getOrCreateRemoteParticipant(sid: otherParticipant.sid, info: otherParticipant)
            }
        }
    }

    func engine(_ engine: Engine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {
        guard streams.count > 0 else {
            log("received onTrack with no streams!", .error)
            return
        }

        let unpacked = streams[0].streamId.unpack()
        let participantSid = unpacked.sid
        var trackSid = unpacked.trackId
        if trackSid == "" {
            trackSid = track.trackId
        }
        let participant = getOrCreateRemoteParticipant(sid: participantSid)

        log("added media track from: \(participantSid), sid: \(trackSid)")

        _ = retry(attempts: 10, delay: 0.2) { _, error in
            // if error is invalidTrackState, retry
            guard case TrackError.state = error else { return false }
            return true
        } _: {
            participant.addSubscribedMediaTrack(rtcTrack: track, sid: trackSid)
        }
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
                _ = onParticipantDisconnect(sid: info.sid, participant: participant)
            } else if isNewParticipant {
                notify { $0.room(self, participantDidJoin: participant) }
            } else {
                participant.updateFromInfo(info: info)
            }
        }
    }

    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket) {
        // participant could be null if data broadcasted from server
        let participant = remoteParticipants[userPacket.participantSid]

        notify { $0.room(self, participant: participant, didReceive: userPacket.payload) }
        participant?.notify { [weak participant] in
            guard let participant = participant else { return }
            $0.participant(participant, didReceive: userPacket.payload)
        }
    }

    func engine(_ engine: Engine, didUpdateRemoteMute trackSid: String, muted: Bool) {
        guard let publication = localParticipant?.tracks[trackSid] as? LocalTrackPublication else { return }
        if muted {
            publication.mute()
        } else {
            publication.unmute()
        }
    }

    func didDisconnect(reason: String, code: UInt16) {
        notify { $0.room(self, didDisconnect: nil) }
    }

    func engine(_ engine: Engine, didFailConnection error: Error) {
        notify { $0.room(self, didFailToConnect: error) }
    }

    func engine(_ engine: Engine, didUpdate trackStates: [Livekit_StreamStateInfo]) {

        for update in trackStates {
            // Try to find RemoteParticipant
            guard let participant = remoteParticipants[update.participantSid] else { continue }
            // Try to find RemoteTrackPublication
            guard let trackPublication = participant.tracks[update.trackSid] as? RemoteTrackPublication else { continue }
            // Update streamState (and notify)
            trackPublication.streamState = update.state.toLKType()
        }
    }
}
