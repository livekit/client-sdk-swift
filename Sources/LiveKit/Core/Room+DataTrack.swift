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

// MARK: - Data Tracks State

/// Session-scoped data track managers and channels, held together so they reset atomically on
/// teardown and stay synchronized across the connect/cleanup and Rust callback threads.
struct DataTracksState: @unchecked Sendable {
    var localManager: LocalDataTrackManager?
    var remoteManager: RemoteDataTrackManager?
    var publisherChannel: LKRTCDataChannel?
    var subscriberChannel: LKRTCDataChannel?
}

// MARK: - Data Track Manager Properties

extension Room {
    func setupDataTrackManagers() {
        let bridge = DataTrackBridge(room: self)
        // Provide the cryptor only when E2EE is configured — its presence is what marks tracks as
        // encrypted (usesE2ee), so it must be nil otherwise.
        let cryptor: DataTrackCryptor? = e2eeManager.map(DataTrackCryptor.init)
        _dataTracks.mutate {
            $0.localManager = LocalDataTrackManager(delegate: bridge, encryptionProvider: cryptor)
            $0.remoteManager = RemoteDataTrackManager(delegate: bridge, decryptionProvider: cryptor)
        }
    }

    func cleanUpDataTrack() {
        _dataTracks.mutate { $0 = DataTracksState() }
    }
}

// MARK: - Subscriber Data Track Channel

extension Room {
    func configureSubscriberDataTrackChannel(_ dataChannel: LKRTCDataChannel) {
        log("Setting subscriber data track channel")
        _dataTracks.mutate { $0.subscriberChannel = dataChannel }
        dataChannel.delegate = subscriberDataTrackChannelDelegate
    }
}

// MARK: - Data Track Bridge

/// Forwards data track manager callbacks to the ``Room``.
///
/// A standalone object rather than ``Room`` itself: the UniFFI managers retain their delegate
/// strongly, so holding ``Room`` weakly here breaks what would otherwise be a retain cycle. One
/// instance serves both managers.
final class DataTrackBridge: LocalDataTrackManagerDelegate, RemoteDataTrackManagerDelegate, @unchecked Sendable {
    private weak var room: Room?
    // Serializes outbound signal requests so they reach the SFU in the order the manager emits
    // them — a bare Task per callback could reorder e.g. a publish/unpublish pair.
    private let signalSender = AsyncSerialDelegate<Room>()

    init(room: Room) {
        self.room = room
        signalSender.set(delegate: room)
    }

    func onSignalRequest(request: Data) {
        signalSender.notifyDetached { room in
            guard let signalRequest = try? Livekit_SignalRequest(serializedBytes: request) else {
                room.log("Failed to decode data track signal request", .warning)
                return
            }
            try? await room.signalClient.sendRequest(signalRequest)
        }
    }

    func onPacketsAvailable(packets: [Data]) {
        guard let room, let channel = room.publisherDataTrackChannel else { return }
        let buffers = packets.map { RTC.createDataBuffer(data: $0) }
        DispatchQueue.liveKitWebRTC.async {
            // ponytail: drop the whole frame when the channel is congested. The DTP channel is
            // unreliable, so dropping beats unbounded buffering; switch to drop-oldest if the
            // newest-frame loss becomes a problem.
            guard channel.bufferedAmount < Self.maxBufferedAmount else {
                room.log("Data track channel congested (\(channel.bufferedAmount) bytes buffered), dropping frame", .warning)
                return
            }
            for buffer in buffers {
                channel.sendData(buffer)
            }
        }
    }

    func onTrackPublished(track: LiveKitUniFFI.RemoteDataTrack) {
        guard let room else { return }
        let dataTrack = RemoteDataTrack(track)
        let identity = Participant.Identity(from: dataTrack.publisherIdentity)
        guard let participant = room.remoteParticipants[identity] else {
            room.log("Data track published by unknown participant \(identity)", .warning)
            return
        }
        participant.addDataTrack(dataTrack)
        room.delegates.notify(label: { "room.didPublishDataTrack" }) {
            $0.room?(room, participant: participant, didPublishDataTrack: dataTrack)
        }
    }

    func onTrackUnpublished(sid: DataTrack.Sid) {
        guard let room else { return }
        for participant in room.remoteParticipants.values where participant.removeDataTrack(sid: sid) != nil {
            room.delegates.notify(label: { "room.didUnpublishDataTrack" }) {
                $0.room?(room, participant: participant, didUnpublishDataTrack: sid)
            }
            return
        }
    }

    // Bound the publisher data track channel buffer; parity with the lossy data channel threshold.
    private static let maxBufferedAmount: UInt64 = 2 * 1024 * 1024
}

// MARK: - Reconnect

extension LocalDataTrackManager {
    /// Restores local publications after a reconnect. Quick reconnect preserves them via sync
    /// state, so only a full reconnect needs to republish.
    func handleReconnect(fullReconnect: Bool) {
        if fullReconnect { republishTracks() }
    }
}

extension RemoteDataTrackManager {
    /// Re-asserts subscriptions after a reconnect so the SFU re-issues subscriber handles.
    func handleReconnect(fullReconnect _: Bool) {
        resendSubscriptionUpdates()
    }
}

// MARK: - Subscriber Data Track Channel Delegate

final class SubscriberDataTrackChannelDelegate: NSObject, LKRTCDataChannelDelegate, @unchecked Sendable {
    private weak var room: Room?

    init(room: Room) {
        self.room = room
    }

    func dataChannelDidChangeState(_: LKRTCDataChannel) {}

    func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        room?.remoteDataTrackManager?.handlePacketReceived(packet: buffer.data)
    }
}
