import Foundation
import Network
import Promises
import WebRTC

public class Room: MulticastDelegate<RoomDelegate> {

    public private(set) var sid: Sid?
    public private(set) var name: String?
    public private(set) var metadata: String?
    public private(set) var serverVersion: String?
    public private(set) var serverRegion: String?
    public private(set) var localParticipant: LocalParticipant?
    public private(set) var remoteParticipants = [Sid: RemoteParticipant]()
    public private(set) var activeSpeakers: [Participant] = []

    // Reference to Engine
    internal let engine: Engine
    internal private(set) var options: RoomOptions

    // expose engine's vars
    public var connectionState: ConnectionState { engine.connectionState }
    public var url: String? { engine.url }
    public var token: String? { engine.token }

    public init(delegate: RoomDelegate? = nil,
                connectOptions: ConnectOptions = ConnectOptions(),
                roomOptions: RoomOptions = RoomOptions()) {

        self.options = roomOptions
        self.engine = Engine(connectOptions: connectOptions,
                             roomOptions: roomOptions)
        super.init()

        // listen to engine & signalClient
        engine.add(delegate: self)
        engine.signalClient.add(delegate: self)

        if let delegate = delegate {
            add(delegate: delegate)
        }

        // listen to app states
        AppStateListener.shared.add(delegate: self)
    }

    deinit {
        log()
    }

    @discardableResult
    public func connect(_ url: String,
                        _ token: String,
                        connectOptions: ConnectOptions? = nil,
                        roomOptions: RoomOptions? = nil) -> Promise<Room> {

        // update options if specified
        self.options = roomOptions ?? self.options

        log("connecting to room", .info)
        guard localParticipant == nil else {
            return Promise(EngineError.state(message: "localParticipant is not nil"))
        }

        // monitor.start(queue: monitorQueue)
        return engine.connect(url, token,
                              connectOptions: connectOptions,
                              roomOptions: roomOptions).then(on: .sdk) { self }
    }

    @discardableResult
    public func disconnect() -> Promise<Void> {
        engine.signalClient.sendLeave()
            .recover(on: .sdk) { self.log("Failed to send leave, error: \($0)") }
            .then(on: .sdk) {
                self.cleanUp(reason: .user)
            }
    }
}

// MARK: - Private

private extension Room {

    // Resets state of Room
    @discardableResult
    private func cleanUp(reason: DisconnectReason) -> Promise<Void> {
        log()

        // Stop all local & remote tracks
        func stopAllTracks() -> Promise<Void> {

            let allParticipants = ([[localParticipant],
                                    remoteParticipants.map { $0.value }] as [[Participant?]])
                .joined()
                .compactMap { $0 }

            let stopPromises = allParticipants.map { $0.tracks.values.map { $0.track } }.joined()
                .compactMap { $0 }
                .map { $0.stop() }

            return stopPromises.all(on: .sdk)
        }

        return engine.cleanUp(reason: reason)
            .then(on: .sdk) {
                stopAllTracks()
            }.recover(on: .sdk) { self.log("Failed to stop all tracks, error: \($0)")
            }.then(on: .sdk) {
                self.sid = nil
                self.name = nil
                self.metadata = nil
                self.serverVersion = nil
                self.serverRegion = nil
                self.localParticipant = nil
                self.remoteParticipants.removeAll()
                self.activeSpeakers.removeAll()
            }
    }

    func getOrCreateRemoteParticipant(sid: Sid, info: Livekit_ParticipantInfo? = nil) -> RemoteParticipant {
        if let participant = remoteParticipants[sid] {
            return participant
        }
        let participant = RemoteParticipant(sid: sid, info: info, room: self)
        remoteParticipants[sid] = participant
        return participant
    }

    func onParticipantDisconnect(sid: Sid, participant: RemoteParticipant) -> Promise<Void> {

        guard let participant = remoteParticipants.removeValue(forKey: sid) else {
            return Promise(EngineError.state(message: "Participant not found for \(sid)"))
        }

        // create array of unpublish promises
        let promises = participant.tracks.values
            .compactMap { $0 as? RemoteTrackPublication }
            .map { participant.unpublish(publication: $0) }

        return promises.all(on: .sdk).then(on: .sdk) {
            self.notify { $0.room(self, participantDidLeave: participant) }
        }
    }

    func onSignalSpeakersUpdate(_ speakers: [Livekit_SpeakerInfo]) {
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

    func onEngineSpeakersUpdate(_ speakers: [Livekit_SpeakerInfo]) {
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

    func onConnectionQualityUpdate(_ connectionQuality: [Livekit_ConnectionQualityInfo]) {

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

    func onSubscribedQualitiesUpdate(trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) {
        localParticipant?.onSubscribedQualitiesUpdate(trackSid: trackSid, subscribedQualities: subscribedQualities)
    }

    func onSubscriptionPermissionUpdate(permissionUpdate: Livekit_SubscriptionPermissionUpdate) {
        guard let participant = remoteParticipants[permissionUpdate.participantSid],
              let publication = participant.getTrackPublication(sid: permissionUpdate.trackSid) else {
            return
        }

        publication.set(subscriptionAllowed: permissionUpdate.allowed)
    }
}

// MARK: - Internal

internal extension Room {

    func set(metadata: String?) {
        guard self.metadata != metadata else { return }
        self.metadata = metadata
        notify { $0.room(self, didUpdate: metadata) }
    }
}

// MARK: - Debugging

extension Room {

    @discardableResult
    public func sendSimulate(scenario: SimulateScenario) -> Promise<Void> {
        engine.signalClient.sendSimulate(scenario: scenario)
    }
}

// MARK: - Session Migration

internal extension Room {

    func sendTrackSettings() -> Promise<Void> {
        log()

        let promises = remoteParticipants.values.map {
            $0.tracks.values
                .compactMap { $0 as? RemoteTrackPublication }
                .filter { $0.subscribed }
                .map { $0.sendCurrentTrackSettings() }
        }.joined()

        return promises.all(on: .sdk)
    }

    func sendSyncState() -> Promise<Void> {

        guard let subscriber = engine.subscriber,
              let localDescription = subscriber.localDescription else {
            // No-op
            return Promise(())
        }

        let sendUnSub = engine.connectOptions.autoSubscribe
        let participantTracks = remoteParticipants.values.map { participant in
            Livekit_ParticipantTracks.with {
                $0.participantSid = participant.sid
                $0.trackSids = participant.tracks.values
                    .filter { $0.subscribed != sendUnSub }
                    .map { $0.sid }
            }
        }

        // Backward compatibility
        let trackSids = participantTracks.map { $0.trackSids }.flatMap { $0 }

        log("trackSids: \(trackSids)")

        let subscription = Livekit_UpdateSubscription.with {
            $0.trackSids = trackSids // Deprecated
            $0.participantTracks = participantTracks
            $0.subscribe = !sendUnSub
        }

        return engine.signalClient.sendSyncState(answer: localDescription.toPBType(),
                                                 subscription: subscription,
                                                 publishTracks: localParticipant?.publishedTracksInfo(),
                                                 dataChannels: engine.dataChannelInfo())
    }
}

// MARK: - SignalClientDelegate

extension Room: SignalClientDelegate {

    func signalClient(_ signalClient: SignalClient, didUpdate connectionState: ConnectionState, oldValue: ConnectionState) -> Bool {
        log()

        guard !connectionState.isEqual(to: oldValue, includingAssociatedValues: false) else {
            log("Skipping same conectionState")
            return true
        }

        if case .quick = self.connectionState.reconnectingWithMode,
           case .quick = connectionState.reconnectedWithMode {
            sendSyncState().catch { error in
                self.log("Failed to sendSyncState, error: \(error)", .error)
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

        log("Server version: \(joinResponse.serverVersion), region: \(joinResponse.serverRegion)", .info)

        sid = joinResponse.room.sid
        name = joinResponse.room.name
        metadata = joinResponse.room.metadata
        serverVersion = joinResponse.serverVersion
        serverRegion = joinResponse.serverRegion.isEmpty ? nil : joinResponse.serverRegion

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

    func signalClient(_ signalClient: SignalClient, didUpdate room: Livekit_Room) -> Bool {
        set(metadata: room.metadata)
        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo]) -> Bool {
        log("speakers: \(speakers)", .trace)

        onSignalSpeakersUpdate(speakers)
        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo]) -> Bool {
        log("connectionQuality: \(connectionQuality)", .trace)

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

        log("trackStates: \(trackStates.map { "(\($0.trackSid): \(String(describing: $0.state)))" }.joined(separator: ", "))")

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

    func engine(_ engine: Engine, didGenerate trackStats: [TrackStats], target: Livekit_SignalTarget) {

        let allParticipants = ([[localParticipant],
                                remoteParticipants.map { $0.value }] as [[Participant?]])
            .joined()
            .compactMap { $0 }

        let allTracks = allParticipants.map { $0.tracks.values.map { $0.track } }.joined()
            .compactMap { $0 }

        // this relies on the last stat entry being the latest
        for track in allTracks {
            if let stats = trackStats.last(where: { $0.trackId == track.mediaTrack.trackId }) {
                track.set(stats: stats)
            }
        }
    }

    func engine(_ engine: Engine, didUpdate speakers: [Livekit_SpeakerInfo]) {
        onEngineSpeakersUpdate(speakers)
    }

    func engine(_ engine: Engine, didUpdate connectionState: ConnectionState, oldValue: ConnectionState) {
        log()

        defer { notify { $0.room(self, didUpdate: connectionState, oldValue: oldValue) } }

        guard !connectionState.isEqual(to: oldValue, includingAssociatedValues: false) else {
            log("Skipping same conectionState")
            return
        }

        // Deprecated
        if case .connected(let mode) = connectionState {
            var didReconnect = false
            if case .reconnect = mode { didReconnect = true }
            // Backward compatibility
            notify { $0.room(self, didConnect: didReconnect) }

            // Re-publish on full reconnect
            if case .reconnect(let rmode) = mode,
               case .full = rmode {
                log("Should re-publish existing tracks")
                localParticipant?.republishTracks().catch { error in
                    self.log("Failed to republish all track, error: \(error)", .error)
                }
            }

        } else if case .disconnected(let reason) = connectionState {
            if case .connected = oldValue {
                // Backward compatibility
                notify { $0.room(self, didDisconnect: reason.error ) }
            } else {
                // Backward compatibility
                notify { $0.room(self, didFailToConnect: reason.error ?? NetworkError.disconnected() ) }
            }

            cleanUp(reason: reason)
        }

        if connectionState.didReconnect {
            // Re-send track settings on a reconnect
            sendTrackSettings().catch { error in
                self.log("Failed to sendTrackSettings, error: \(error)", .error)
            }
        }
    }

    func engine(_ engine: Engine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {

        guard !streams.isEmpty else {
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

    func engine(_ engine: Engine, didRemove track: RTCMediaStreamTrack) {
        // find the publication
        guard let publication = remoteParticipants.values.map { $0.tracks.values }.joined()
                .first(where: { $0.sid == track.trackId }) else { return }
        publication.set(track: nil)
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

// MARK: - AppStateDelegate

extension Room: AppStateDelegate {

    func appDidEnterBackground() {

        guard options.suspendLocalVideoTracksInBackground else { return }

        guard let localParticipant = localParticipant else { return }
        let promises = localParticipant.localVideoTracks.map { $0.suspend() }

        guard !promises.isEmpty else { return }

        all(promises).then { _ in
            self.log("suspended all video tracks")
        }
    }

    func appWillEnterForeground() {

        guard let localParticipant = localParticipant else { return }
        let promises = localParticipant.localVideoTracks.map { $0.resume() }

        guard !promises.isEmpty else { return }

        all(promises).then { _ in
            self.log("resumed all video tracks")
        }
    }
}
