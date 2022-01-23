import Foundation
import Network
import Promises
import WebRTC

public class Room: MulticastDelegate<RoomDelegate> {

    public private(set) var sid: Sid?
    public private(set) var name: String?
    public private(set) var localParticipant: LocalParticipant?
    public private(set) var remoteParticipants = [Sid: RemoteParticipant]()
    public private(set) var activeSpeakers: [Participant] = []

    // Reference to Engine
    internal lazy var engine = Engine(room: self)

    internal private(set) var connectOptions: ConnectOptions?
    internal private(set) var roomOptions: RoomOptions?

    // expose engine's vars
    public var connectionState: ConnectionState { engine.connectionState }
    public var url: String? { engine.url }
    public var token: String? { engine.token }

    public init(delegate: RoomDelegate? = nil,
                connectOptions: ConnectOptions? = nil,
                roomOptions: RoomOptions? = nil) {

        self.connectOptions = connectOptions
        self.roomOptions = roomOptions
        super.init()

        if let delegate = delegate {
            add(delegate: delegate)
        }
    }

    deinit {
        // not really required to remove delegate since it's weak
        engine.remove(delegate: self)
    }

    internal func cleanUp(reason: DisconnectReason) -> Promise<Void> {

        engine.cleanUp(reason: reason)

        // Stop all local & remote track

        let allParticipants = ([[localParticipant],
                                remoteParticipants.map { $0.value }] as [[Participant?]])
            .joined()
            .compactMap { $0 }

        let stopPromises = allParticipants.map { $0.tracks.values.map { $0.track } }.joined()
            .compactMap { $0 }
            .map { $0.stop() }

        return all(on: .sdk, stopPromises).then(on: .sdk) { (_) -> Void in
            self.localParticipant = nil
            self.remoteParticipants.removeAll()
            self.activeSpeakers.removeAll()
        }
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
        return cleanUp(reason: .user)
    }

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
}

extension Room {

    @discardableResult
    public func sendSimulate(scenario: SimulateScenario) -> Promise<Void> {
        engine.signalClient.sendSimulate(scenario: scenario)
    }
}

// MARK: - Session Migration

extension Room {

    internal func sendSyncState() -> Promise<Void> {
        log()

        guard let subscriber = engine.subscriber,
              let localDescription = subscriber.localDescription else {
            // No-op
            return Promise(())
        }

        let sendUnSub = connectOptions?.autoSubscribe ?? false
        let trackSids = remoteParticipants.values.map {
            $0.tracks.values
                .filter { $0.subscribed != sendUnSub }
                .map { $0.sid }
        }.flatMap { $0 }

        log("trackSids: \(trackSids)")

        let subscription = Livekit_UpdateSubscription.with {
            $0.trackSids = trackSids
            $0.subscribe = !sendUnSub
            $0.participantTracks = []
        }

        return engine.signalClient.sendSyncState(answer: localDescription.toPBType(),
                                                 subscription: subscription,
                                                 publishTracks: localParticipant?.publishedTracksInfo())
    }
}

// MARK: - SignalClientDelegate

extension Room: SignalClientDelegate {

    func signalClient(_ signalClient: SignalClient, didUpdate connectionState: ConnectionState) -> Bool {
        log()

        if connectionState.isReconnecting {
            sendSyncState().catch { error in
                self.log("Failed to send sync state, error: \(error)", .error)
            }
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) -> Bool {
        log()

        onSubscribedQualitiesUpdate(trackSid: trackSid,
                                    subscribedQualities: subscribedQualities)
        return true
    }

    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse) -> Bool {
        log("Server version: \(joinResponse.serverVersion)", .info)

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

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo]) -> Bool {
        log("speakers: \(speakers)")

        onSignalSpeakersUpdate(speakers)
        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo]) -> Bool {
        log("connectionQuality: \(connectionQuality)")

        onConnectionQualityUpdate(connectionQuality)
        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool) -> Bool {
        log("trackSid: \(trackSid) muted: \(muted)")

        guard let publication = localParticipant?.tracks[trackSid] as? LocalTrackPublication else {
            // publication was not found but the delegate was handled
            return true
        }

        if muted {
            publication.mute()
        } else {
            publication.unmute()
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate subscriptionPermission: Livekit_SubscriptionPermissionUpdate) -> Bool {
        log("subscriptionPermission: \(subscriptionPermission)")

        onSubscriptionPermissionUpdate(permissionUpdate: subscriptionPermission)
        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate trackStates: [Livekit_StreamStateInfo]) -> Bool {
        log("trackStates: \(trackStates)")

        for update in trackStates {
            // Try to find RemoteParticipant
            guard let participant = remoteParticipants[update.participantSid] else { continue }
            // Try to find RemoteTrackPublication
            guard let trackPublication = participant.tracks[update.trackSid] as? RemoteTrackPublication else { continue }
            // Update streamState (and notify)
            trackPublication.streamState = update.state.toLKType()
        }
        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate participants: [Livekit_ParticipantInfo]) -> Bool {
        log("participants: \(participants)")

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
        return true
    }
}

// MARK: - EngineDelegate

extension Room: EngineDelegate {

    func engine(_ engine: Engine, didUpdate speakers: [Livekit_SpeakerInfo]) {
        onEngineSpeakersUpdate(speakers)
    }

    func engine(_ engine: Engine, didUpdate connectionState: ConnectionState, oldState: ConnectionState) {

        // Deprecated
        if case .connected(let didReconnect) = connectionState {
            notify { $0.room(self, didConnect: didReconnect) }
        } else if case .disconnected(let reason) = connectionState {
            if case .connected = oldState {
                notify { $0.room(self, didDisconnect: reason?.error ) }
            } else {
                notify { $0.room(self, didFailToConnect: reason?.error ?? NetworkError.disconnected() ) }
            }
        }

        notify { $0.room(self, didUpdate: connectionState) }
    }

    func engine(_ engine: Engine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {

        guard streams.count > 0 else {
            log("Received onTrack with no streams!", .warning)
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

    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket) {
        // participant could be null if data broadcasted from server
        let participant = remoteParticipants[userPacket.participantSid]

        notify { $0.room(self, participant: participant, didReceive: userPacket.payload) }
        participant?.notify { [weak participant] (delegate) -> Void in
            guard let participant = participant else { return }
            delegate.participant(participant, didReceive: userPacket.payload)
        }
    }
}
