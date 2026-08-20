/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

internal import LiveKitUniFFI
internal import LiveKitWebRTC

// MARK: - DataTracks

/// Owns the local/remote data track managers, the data channels, and the manager-delegate shim,
/// and routes Room/participant calls to the right manager. The ``Room`` holds a single reference,
/// keeping the subsystem off the Room's surface. Session-scoped: created at connect and kept across
/// reconnects (its channels are swapped, but the managers persist so publications can be
/// republished), released only on a real disconnect.
///
/// `@unchecked Sendable`: every mutable field is StateSync-guarded; the delegate, cryptor and
/// remote manager are immutable after init. Not an actor — the UniFFI delegate callbacks are
/// synchronous and can't `await`.
final class DataTracks: NSObject, @unchecked Sendable {
    // Built on the first publish, not at connect: the manager captures whether outbound frames
    // are encrypted (see `encryptionProvider`), and deferring it lets a `setE2EEEnabled(true)`
    // issued after connecting still apply. Until then there is nothing for it to do — every call
    // it serves concerns tracks this participant has published.
    private let _local = StateSync<LocalDataTrackManager?>(nil)
    private let remote: RemoteDataTrackManager
    private let managerDelegate: ManagerDelegate
    private let cryptor: DataTrackCryptor
    private weak var room: Room?
    // The subscriber channel is retained (not just delegated) because its Swift wrapper must stay
    // alive for native callbacks to reach us. The publisher channel is owned by `publisher`.
    private let _subscriberChannel = StateSync<LKRTCDataChannel?>(nil)
    // Resolves when the publisher data-track channel reaches `.open`; reset when the channel is
    // swapped on a full reconnect. Gates publishing so frames aren't dropped into a closed channel.
    private let _publisherChannelOpen = AsyncCompleter<Void>(label: "Data track publisher channel open", defaultTimeout: .defaultTransportState)
    // Whether this session ever published, so a full reconnect knows to re-establish the
    // publisher transport (media republishing only does this for media publishers).
    private let _hasPublished = StateSync<Bool>(false)
    // Live remote tracks. Kept here — not only on the participants — because participant objects
    // are discarded on a full reconnect while this subsystem (and the manager's track state)
    // survives, so the manager won't re-announce tracks it already knows; see
    // `reattachRemoteTracks`.
    private let _remoteTracks = StateSync<[RemoteDataTrack]>([])

    // Outbound frame drain, and the owner of the publisher channel (including its delegate slot).
    // Drop-oldest with a capacity of one frame: a newer frame evicts the one waiting, and frames
    // are dispatched whole so a partial frame never reaches the wire.
    // Implicitly unwrapped because its callbacks capture `self`; assigned in `init` before `self`
    // escapes (the FFI reaches it only after `managerDelegate.coordinator = self`, the last line),
    // which is the ordering that makes the unsynchronized read from the Rust callback thread safe.
    // Keep it that way.
    private var publisher: DataChannelDrain<DataTrackStage>!

    init(room: Room) {
        self.room = room
        let managerDelegate = ManagerDelegate(room: room)
        self.managerDelegate = managerDelegate
        // Reception can always decrypt; only publishing consults the toggle. The cryptor resolves
        // the room's E2EE manager per call, so one assigned after connecting still applies.
        cryptor = DataTrackCryptor(room: room)
        remote = RemoteDataTrackManager(delegate: managerDelegate, decryptionProvider: cryptor)
        super.init()
        publisher = DataChannelDrain(
            label: LKRTCDataChannel.Labels.dataTrack,
            lowWaterMark: Self.frameLowWaterMark,
            overflow: .dropOldest,
            stage: DataTrackStage(),
            onMessage: { [weak self] data in self?.handlePacket(data) },
            onStateChange: { [weak self] channel in self?.handlePublisherStateChange(channel) },
            onBufferStatusChange: { [weak room] isLow in room?.notify(bufferStatus: isLow, of: .dataTrack) },
        )
        // The UniFFI managers retain their delegate strongly, so it points back here weakly to
        // avoid a cycle. (The RTC channel holds its delegate — us — weakly, so no shim needed.)
        managerDelegate.coordinator = self
    }

    /// The publishing manager, created on first use. Whether frames are encrypted is fixed when
    /// it is built: unlike data channel payloads (a per-message property), data track encryption
    /// is a track-level protocol property that subscribers key their decryption on, so it can't
    /// be consulted per frame. The cryptor is passed only when E2EE is on — its presence is what
    /// marks published tracks as encrypted (``DataTrackInfo/usesE2ee``).
    private var local: LocalDataTrackManager {
        _local.mutate { manager in
            if let manager { return manager }
            let encryptionProvider = room?.e2eeManager?.isDataTrackEncryptionEnabled == true ? cryptor : nil
            let created = LocalDataTrackManager(delegate: managerDelegate, encryptionProvider: encryptionProvider)
            manager = created
            return created
        }
    }

    // MARK: - Publishing

    func publish(name: String, options: DataTrackPublishOptions? = nil) async throws -> LocalDataTrack {
        // A data-track-only publisher in subscriber-primary mode has no negotiated publisher
        // transport yet — establish it and wait for the channel to open, or frames would be
        // silently dropped (`sendData` on a non-open channel fails). Gate failures are reported
        // as publish errors, since that's what the caller asked for.
        do {
            try await room?.ensurePublisherConnected()
            try await _publisherChannelOpen.wait()
        } catch let error as LiveKitError where error.type == .timedOut {
            throw DataTrackPublishError.timeout("Timed out establishing the publisher data track channel")
        } catch let error as LiveKitError where error.type == .cancelled {
            // Cancellation is the caller's own doing; laundering it into a publish error would
            // make a cancelled publish indistinguishable from a lost connection.
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DataTrackPublishError.disconnected("Lost the connection while establishing the publisher data track channel")
        }
        do {
            let ffiOptions = DataTrackOptions(name: name,
                                              schema: options?.schema?.ffi,
                                              frameEncoding: options?.frameEncoding?.ffi)
            let track = try await local.publishTrack(options: ffiOptions)
            _hasPublished.mutate { $0 = true }
            return LocalDataTrack(track)
        } catch let error as PublishError {
            throw DataTrackPublishError(error)
        }
    }

    // MARK: - Signaling

    /// Surfaces data tracks published by participants already in the room when we joined.
    /// Takes the response as received: the manager decodes it itself, and re-encoding our decoded
    /// copy would drop any field newer than the pinned protocol.
    func handleJoinResponse(_ encoded: Data) {
        try? remote.handleSfuJoinResponse(res: encoded)
        reattachRemoteTracks()
    }

    func handleSignalResponse(_ data: Data) {
        // Each manager handles specific message types and returns UnsupportedType otherwise, so
        // try them all. Participant updates are routed via handleParticipantUpdate instead, after
        // the remote participant is added — so onTrackPublished can resolve the publisher.
        // `_local` rather than `local`: these only matter once something has been published, and
        // building the manager here would fix the encryption mode before the first publish.
        if let local = _local.copy() {
            try? local.handleSfuRequestResponse(res: data)
            try? local.handleSfuPublishResponse(res: data)
        }
        try? remote.handleSubscriberHandles(res: data)
    }

    /// As received, for the same reason as ``handleJoinResponse(_:)``.
    func handleParticipantUpdate(_ encoded: Data, localIdentity: String) {
        try? remote.handleSfuParticipantUpdate(res: encoded, localParticipantIdentity: localIdentity)
        // A track announced before its publisher was registered is parked in `_remoteTracks`;
        // now that participants are current, attach any such stragglers.
        reattachRemoteTracks()
    }

    func handleRoomMoved(_ participants: [Livekit_ParticipantInfo], localIdentity: String) {
        // The old room's tracks are gone for good, so forget them instead of keeping them for
        // re-attach. Dropped silently: the move tears every participant down first, and
        // `unpublishAll` has already reported each attached track — reporting again here would
        // double up for any publisher that moved with us and has since been recreated. A track
        // still parked here was never attached, so no publish was reported for it either.
        _remoteTracks.mutate { $0 = [] }
        _local.copy()?.republishTracks()
        // The one place bytes can't be threaded: the SFU sends a `RoomMovedResponse` while the
        // manager consumes a `ParticipantUpdate`, so this one is built — and stays lossy.
        let response = Livekit_SignalResponse.with {
            $0.update = Livekit_ParticipantUpdate.with { $0.participants = participants }
        }
        guard let encoded = try? response.serializedData() else { return }
        handleParticipantUpdate(encoded, localIdentity: localIdentity)
    }

    /// Handles the room discarding its transports for a full reconnect: the publisher channel is
    /// dead, so re-arm the open gate — a publish issued before the replacement channel arrives
    /// waits for it instead of proceeding against the torn-down transport. (The channel's own
    /// `.closed` delegate callback re-arms too, but arrives asynchronously from WebRTC's thread.)
    func handleTransportsTeardown() {
        _publisherChannelOpen.rearm()
        // The channel dies with the transport: drop queued frames (stale by definition on this
        // drop-oldest channel) and mark the close as expected so it isn't logged as an error.
        publisher.reset()
    }

    func handleReconnect(fullReconnect: Bool) {
        // Quick reconnect preserves local publications via sync state, so only a full reconnect
        // republishes. Either way, re-assert subscriptions so the SFU re-issues subscriber handles.
        if fullReconnect {
            _local.copy()?.republishTracks()
            // A data-track-only publisher needs the publisher transport re-established too; the
            // media republish path only does this when media tracks exist. Gate waiters are
            // publishes that arrived during the reconnect window — their own
            // `ensurePublisherConnected` ran against the torn-down transport and was a no-op.
            if _hasPublished.copy() || _publisherChannelOpen.waiterCount > 0, let room {
                Task { try? await room.ensurePublisherConnected() }
            }
        }
        remote.resendSubscriptionUpdates()
    }

    /// Publish responses for the local data tracks, for `SyncState.publishDataTracks` on quick
    /// reconnect (so the SFU keeps the publications without a full republish).
    func syncStatePublishResponses() async -> [Livekit_PublishDataTrackResponse] {
        guard let local = _local.copy() else { return [] }
        return await local.publishResponsesForSyncState().compactMap { try? Livekit_PublishDataTrackResponse(serializedBytes: $0) }
    }

    func handlePacket(_ data: Data) {
        remote.handlePacketReceived(packet: data)
    }

    // MARK: - Remote Tracks

    fileprivate func remoteTrackPublished(_ track: RemoteDataTrack) {
        guard let room else { return }
        _remoteTracks.mutate { $0.append(track) }
        let identity = track.publisherIdentity
        guard let participant = room.remoteParticipants[identity] else {
            // The callback can race the participant's registration; the track stays in
            // `_remoteTracks` and attaches on the next participant update.
            room.log("Data track published by not-yet-known participant \(identity)", .debug)
            return
        }
        attach(track, to: participant, in: room)
    }

    fileprivate func remoteTrackUnpublished(sid: DataTrack.Sid) {
        guard let room else { return }
        // `info` crosses the FFI boundary, so match before taking the lock and remove by identity.
        let unpublished = _remoteTracks.copy().filter { $0.info.sid == sid }
        _remoteTracks.mutate { $0.removeAll { track in unpublished.contains { $0 === track } } }
        // Resolved from the track's own publisher, not from wherever it happens to be attached: a
        // full reconnect detaches tracks from their participants, so a publisher unpublishing in
        // that window would otherwise vanish with no event. (Rust dispatches unconditionally; the
        // lookup exists only because the Swift delegates carry a participant.) The removal above
        // keeps this idempotent.
        for track in unpublished {
            guard let participant = room.remoteParticipants[track.publisherIdentity] else { continue }
            participant.removeDataTrack(sid: sid)
            participant.delegates.notify(label: { "participant.didUnpublishDataTrack" }) {
                $0.participant?(participant, didUnpublishDataTrack: sid)
            }
            room.delegates.notify(label: { "room.didUnpublishDataTrack" }) {
                $0.room?(room, participant: participant, didUnpublishDataTrack: sid)
            }
        }
    }

    /// Attaches parked remote tracks to participants that have since become known: after a full
    /// reconnect's join response (participants are recreated) and after participant updates (a
    /// publish callback can precede its publisher's registration). Idempotent — skips tracks
    /// already attached and publishers still missing.
    private func reattachRemoteTracks() {
        guard let room else { return }
        for track in _remoteTracks.copy() {
            guard let participant = room.remoteParticipants[track.publisherIdentity] else { continue }
            attach(track, to: participant, in: room)
        }
    }

    /// No-op (and no events) when this exact track is already attached.
    private func attach(_ track: RemoteDataTrack, to participant: RemoteParticipant, in room: Room) {
        guard participant.addDataTrack(track) else { return }
        participant.delegates.notify(label: { "participant.didPublishDataTrack" }) {
            $0.participant?(participant, didPublishDataTrack: track)
        }
        room.delegates.notify(label: { "room.didPublishDataTrack" }) {
            $0.room?(room, participant: participant, didPublishDataTrack: track)
        }
    }

    // MARK: - Channels

    func setPublisherChannel(_ channel: LKRTCDataChannel) {
        // A new channel usually arrives unopened (e.g. swapped in by a full reconnect); re-arm the
        // gate without cancelling waiters — a publish issued during the reconnect window keeps
        // waiting for this channel to open. `setChannel` reports the channel's current state, so
        // `handlePublisherStateChange` resolves the gate if it is already open — no probe here.
        // Frames queued for the old channel belong to the torn-down transport, which `.dropOldest`
        // discards on attach.
        _publisherChannelOpen.rearm()
        publisher.setChannel(channel)
    }

    func setSubscriberChannel(_ channel: LKRTCDataChannel) {
        // Retain the channel — its wrapper must outlive this call for native callbacks to reach our
        // LKRTCDataChannelDelegate conformance below — and route its received packets to us.
        _subscriberChannel.mutate { $0 = channel }
        channel.delegate = self
    }

    // MARK: - Manager Delegate

    /// Receives the UniFFI managers' callbacks and forwards them to the Room. A separate object
    /// rather than ``DataTracks`` itself because the managers retain their delegate strongly: were
    /// the owner also the delegate, `manager → owner → manager` would never break, the DropGuard
    /// would never fire, and teardown would leak. Holding the coordinator and room weakly makes
    /// this the weak link in that graph. One instance serves both managers.
    private final class ManagerDelegate: LocalDataTrackManagerDelegate, RemoteDataTrackManagerDelegate, @unchecked Sendable {
        private weak var room: Room?
        weak var coordinator: DataTracks?
        // Outbound signal requests are yielded into this FIFO stream and drained by a single
        // consumer task, so they reach the SFU in the order the managers emit them — a task per
        // callback could be scheduled out of order and swap e.g. a publish/unpublish pair.
        private let signalRequests: AsyncStream<Data>.Continuation

        init(room: Room) {
            self.room = room
            let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
            signalRequests = continuation
            Task { [weak room] in
                for await request in stream {
                    guard let room else { break }
                    guard let signalRequest = try? Livekit_SignalRequest(serializedBytes: request) else {
                        room.log("Failed to decode data track signal request", .warning)
                        continue
                    }
                    try? await room.signalClient.sendRequest(signalRequest)
                }
            }
        }

        deinit {
            signalRequests.finish()
        }

        func onSignalRequest(request: Data) {
            signalRequests.yield(request)
        }

        func onPacketsAvailable(packets: [Data]) {
            coordinator?.publisher.submit(packets)
        }

        func onTrackPublished(track: LiveKitUniFFI.RemoteDataTrack) {
            coordinator?.remoteTrackPublished(RemoteDataTrack(track))
        }

        func onTrackUnpublished(sid: LiveKitUniFFI.DataTrackSid) {
            coordinator?.remoteTrackUnpublished(sid: DataTrack.Sid(from: sid))
        }
    }
}

// MARK: - Publisher readiness

private extension DataTracks {
    /// Resume sending when this many bytes or fewer are outstanding; parity with
    /// `DATA_TRACK_BUFFERED_AMOUNT_LOW_THRESHOLD` in rust-sdks.
    static var frameLowWaterMark: UInt64 { 8 * 1024 }

    /// Reported by the publisher drain, which owns that channel's delegate slot.
    func handlePublisherStateChange(_ channel: LKRTCDataChannel) {
        if channel.readyState == .open {
            _publisherChannelOpen.resume(returning: ())
        } else {
            // The channel left `.open` (transport teardown or failure): re-arm the gate so a
            // publish issued before the replacement channel arrives waits instead of proceeding
            // against a dead transport.
            _publisherChannelOpen.rearm()
        }
    }
}

// MARK: - Subscriber Channel Delegate

// Only the subscriber channel routes here — the publisher channel's delegate is its drain — so
// there is nothing to disambiguate.
extension DataTracks: LKRTCDataChannelDelegate {
    func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        handlePacket(buffer.data)
    }

    // Required by the protocol. The subscriber channel's readiness is not acted on: it carries no
    // outbound work, and its packets arrive whenever the SFU sends them.
    func dataChannelDidChangeState(_: LKRTCDataChannel) {}
}
