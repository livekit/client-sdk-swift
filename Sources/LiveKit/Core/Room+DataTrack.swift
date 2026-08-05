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
/// `@unchecked Sendable`: the only mutable state is `_publisherChannel` (StateSync-guarded); the
/// managers and delegate are immutable after init. Not an actor — the UniFFI delegate callbacks
/// are synchronous and can't `await`.
final class DataTracks: NSObject, @unchecked Sendable {
    private let local: LocalDataTrackManager
    private let remote: RemoteDataTrackManager
    private weak var room: Room?
    // Wired in after creation (Engine/TransportDelegate) and read from the Rust callback thread,
    // so they need their own synchronization. The subscriber channel is retained (not just
    // delegated) because its Swift wrapper must stay alive for native callbacks to reach us.
    private let _publisherChannel = StateSync<LKRTCDataChannel?>(nil)
    private let _subscriberChannel = StateSync<LKRTCDataChannel?>(nil)
    // Live remote tracks. Kept here — not only on the participants — because participant objects
    // are discarded on a full reconnect while this subsystem (and the manager's track state)
    // survives, so the manager won't re-announce tracks it already knows; see
    // `reattachRemoteTracks`.
    private let _remoteTracks = StateSync<[RemoteDataTrack]>([])

    var publisherChannel: LKRTCDataChannel? { _publisherChannel.copy() }

    init(room: Room) {
        self.room = room
        let managerDelegate = ManagerDelegate(room: room)
        // Provide the cryptor only when E2EE is configured — its presence is what marks tracks as
        // encrypted (usesE2ee), so it must be nil otherwise.
        let cryptor: DataTrackCryptor? = room.e2eeManager.map(DataTrackCryptor.init)
        local = LocalDataTrackManager(delegate: managerDelegate, encryptionProvider: cryptor)
        remote = RemoteDataTrackManager(delegate: managerDelegate, decryptionProvider: cryptor)
        super.init()
        // The UniFFI managers retain their delegate strongly, so it points back here weakly to
        // avoid a cycle. (The RTC channel holds its delegate — us — weakly, so no shim needed.)
        managerDelegate.coordinator = self
    }

    // MARK: - Publishing

    func publish(name: String) async throws -> LocalDataTrack {
        do {
            let track = try await local.publishTrack(options: DataTrackOptions(name: name))
            return LocalDataTrack(track)
        } catch let error as PublishError {
            throw DataTrackPublishError(error)
        }
    }

    // MARK: - Signaling

    func handleJoinResponse(_ joinResponse: Livekit_JoinResponse) {
        // Surfaces data tracks published by participants already in the room when we joined. The
        // FFI takes raw bytes, so wrap the join back into a SignalResponse.
        let response = Livekit_SignalResponse.with { $0.join = joinResponse }
        guard let data = try? response.serializedData() else { return }
        try? remote.handleSfuJoinResponse(res: data)
        reattachRemoteTracks()
    }

    func handleSignalResponse(_ data: Data) {
        // Each manager handles specific message types and returns UnsupportedType otherwise, so
        // try them all. Participant updates are routed via handleParticipantUpdate instead, after
        // the remote participant is added — so onTrackPublished can resolve the publisher.
        try? local.handleSfuRequestResponse(res: data)
        try? local.handleSfuPublishResponse(res: data)
        try? remote.handleSubscriberHandles(res: data)
    }

    func handleParticipantUpdate(_ participants: [Livekit_ParticipantInfo], localIdentity: String) {
        // The FFI takes raw bytes, so rebuild the response from the parsed participants.
        let response = Livekit_SignalResponse.with {
            $0.update = Livekit_ParticipantUpdate.with { $0.participants = participants }
        }
        guard let data = try? response.serializedData() else { return }
        try? remote.handleSfuParticipantUpdate(res: data, localParticipantIdentity: localIdentity)
    }

    func handleReconnect(fullReconnect: Bool) {
        // Quick reconnect preserves local publications via sync state, so only a full reconnect
        // republishes. Either way, re-assert subscriptions so the SFU re-issues subscriber handles.
        if fullReconnect { local.republishTracks() }
        remote.resendSubscriptionUpdates()
    }

    /// Publish responses for the local data tracks, for `SyncState.publishDataTracks` on quick
    /// reconnect (so the SFU keeps the publications without a full republish).
    func syncStatePublishResponses() async -> [Livekit_PublishDataTrackResponse] {
        await local.publishResponsesForSyncState().compactMap { try? Livekit_PublishDataTrackResponse(serializedBytes: $0) }
    }

    func handlePacket(_ data: Data) {
        remote.handlePacketReceived(packet: data)
    }

    // MARK: - Remote Tracks

    fileprivate func remoteTrackPublished(_ track: RemoteDataTrack) {
        guard let room else { return }
        _remoteTracks.mutate { $0.append(track) }
        let identity = Participant.Identity(from: track.publisherIdentity)
        guard let participant = room.remoteParticipants[identity] else {
            room.log("Data track published by unknown participant \(identity)", .warning)
            return
        }
        attach(track, to: participant, in: room)
    }

    fileprivate func remoteTrackUnpublished(sid: DataTrack.Sid) {
        guard let room else { return }
        _remoteTracks.mutate { $0.removeAll { $0.info.sid == sid } }
        for participant in room.remoteParticipants.values where participant.removeDataTrack(sid: sid) != nil {
            participant.delegates.notify(label: { "participant.didUnpublishDataTrack" }) {
                $0.participant?(participant, didUnpublishDataTrack: sid)
            }
            room.delegates.notify(label: { "room.didUnpublishDataTrack" }) {
                $0.room?(room, participant: participant, didUnpublishDataTrack: sid)
            }
            return
        }
    }

    /// Re-attaches live remote tracks to the participants recreated from a full reconnect's join
    /// response. No-op on the initial join (nothing registered yet) and for tracks already
    /// attached.
    private func reattachRemoteTracks() {
        guard let room else { return }
        for track in _remoteTracks.copy() {
            guard let participant = room.remoteParticipants[Participant.Identity(from: track.publisherIdentity)],
                  participant.dataTracks[track.info.sid] == nil else { continue }
            attach(track, to: participant, in: room)
        }
    }

    private func attach(_ track: RemoteDataTrack, to participant: RemoteParticipant, in room: Room) {
        participant.addDataTrack(track)
        participant.delegates.notify(label: { "participant.didPublishDataTrack" }) {
            $0.participant?(participant, didPublishDataTrack: track)
        }
        room.delegates.notify(label: { "room.didPublishDataTrack" }) {
            $0.room?(room, participant: participant, didPublishDataTrack: track)
        }
    }

    // MARK: - Channels

    func setPublisherChannel(_ channel: LKRTCDataChannel) {
        _publisherChannel.mutate { $0 = channel }
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
            guard let channel = coordinator?.publisherChannel else { return }
            let buffers = packets.map { RTC.createDataBuffer(data: $0) }
            DispatchQueue.liveKitWebRTC.async { [weak room] in
                // ponytail: drop the whole frame when the channel is congested. The DTP channel is
                // unreliable, so dropping beats unbounded buffering; switch to drop-oldest if the
                // newest-frame loss becomes a problem.
                guard channel.bufferedAmount < Self.maxBufferedAmount else {
                    room?.log("Data track channel congested (\(channel.bufferedAmount) bytes buffered), dropping frame", .warning)
                    return
                }
                for buffer in buffers {
                    channel.sendData(buffer)
                }
            }
        }

        func onTrackPublished(track: LiveKitUniFFI.RemoteDataTrack) {
            coordinator?.remoteTrackPublished(RemoteDataTrack(track))
        }

        func onTrackUnpublished(sid: DataTrack.Sid) {
            coordinator?.remoteTrackUnpublished(sid: sid)
        }

        // Bound the publisher data track channel buffer; parity with the lossy data channel threshold.
        private static let maxBufferedAmount: UInt64 = 2 * 1024 * 1024
    }
}

// MARK: - Subscriber Channel Delegate

extension DataTracks: LKRTCDataChannelDelegate {
    func dataChannelDidChangeState(_: LKRTCDataChannel) {}

    func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        handlePacket(buffer.data)
    }
}

// MARK: - Lifecycle

extension Room {
    func setupDataTracks() {
        _dataTracks.mutate { $0 = DataTracks(room: self) }
    }

    func cleanUpDataTracks(isFullReconnect: Bool = false) {
        // Session-scoped: keep the subsystem across a full reconnect so its managers can republish;
        // tear it down only on a real disconnect.
        guard !isFullReconnect else { return }
        _dataTracks.mutate { $0 = nil }
    }
}
