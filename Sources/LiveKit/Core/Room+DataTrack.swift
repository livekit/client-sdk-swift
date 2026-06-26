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

// MARK: - Data Track Manager Properties

extension Room {
    func setupDataTrackManagers() {
        let bridge = DataTrackBridge(room: self)
        // Provide E2EE adapters only when E2EE is configured — their presence is what marks tracks
        // as encrypted (usesE2ee), so they must be nil otherwise.
        let encryptionProvider: EncryptionProvider? = e2eeManager.map(DataTrackEncryptionProvider.init)
        let decryptionProvider: DecryptionProvider? = e2eeManager.map(DataTrackDecryptionProvider.init)
        localDataTrackManager = LocalDataTrackManager(
            delegate: bridge,
            encryptionProvider: encryptionProvider,
        )
        remoteDataTrackManager = RemoteDataTrackManager(
            delegate: bridge,
            decryptionProvider: decryptionProvider,
        )
    }

    func cleanUpDataTrack() {
        publisherDataTrackChannel = nil
        subscriberDataTrackChannel = nil
        localDataTrackManager = nil
        remoteDataTrackManager = nil
    }
}

// MARK: - Subscriber Data Track Channel

extension Room {
    func configureSubscriberDataTrackChannel(_ dataChannel: LKRTCDataChannel) {
        log("Setting subscriber data track channel")
        subscriberDataTrackChannel = dataChannel
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

    init(room: Room) {
        self.room = room
    }

    func onSignalRequest(request: Data) {
        guard let room else { return }
        guard let signalRequest = try? Livekit_SignalRequest(serializedBytes: request) else {
            room.log("Failed to decode data track signal request", .warning)
            return
        }
        Task {
            try? await room.signalClient.sendRequest(signalRequest)
        }
    }

    func onPacketsAvailable(packets: [Data]) {
        guard let room, let channel = room.publisherDataTrackChannel else { return }
        let buffers = packets.map { RTC.createDataBuffer(data: $0) }
        DispatchQueue.liveKitWebRTC.sync {
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

    func onTrackPublished(track: RemoteDataTrack) {
        guard let room else { return }
        let identity = Participant.Identity(from: track.publisherIdentity())
        room.remoteParticipants[identity]?.addDataTrack(track)
        room.dataTrackDelegates.notify(label: { "room.didPublishDataTrack" }) {
            $0.room(room, didPublishDataTrack: track)
        }
    }

    func onTrackUnpublished(sid: String) {
        guard let room else { return }
        for participant in room.remoteParticipants.values where participant.removeDataTrack(sid: sid) != nil {
            break
        }
        room.dataTrackDelegates.notify(label: { "room.didUnpublishDataTrack" }) {
            $0.room(room, didUnpublishDataTrack: sid)
        }
    }

    // Bound the publisher data track channel buffer; parity with the lossy data channel threshold.
    private static let maxBufferedAmount: UInt64 = 2 * 1024 * 1024
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
