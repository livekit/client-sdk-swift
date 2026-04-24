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
        let localBridge = LocalDataTrackBridge(room: self)
        localDataTrackManager = LocalDataTrackManager(
            delegate: localBridge,
            encryptionProvider: nil // TODO: E2EE bridge in Phase 1f
        )

        let remoteBridge = RemoteDataTrackBridge(room: self)
        remoteDataTrackManager = RemoteDataTrackManager(
            delegate: remoteBridge,
            decryptionProvider: nil // TODO: E2EE bridge in Phase 1f
        )
    }

    func cleanUpDataTrackManagers() {
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

// MARK: - Local Data Track Bridge

final class LocalDataTrackBridge: LocalDataTrackManagerDelegate, @unchecked Sendable {
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
        for packet in packets {
            let buffer = RTC.createDataBuffer(data: packet)
            DispatchQueue.liveKitWebRTC.sync {
                channel.sendData(buffer)
            }
        }
    }
}

// MARK: - Remote Data Track Bridge

final class RemoteDataTrackBridge: RemoteDataTrackManagerDelegate, @unchecked Sendable {
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

    func onTrackPublished(track: RemoteDataTrack) {
        guard let room else { return }
        room.dataTrackDelegates.notify(label: { "room.didPublishDataTrack" }) {
            $0.room(room, didPublishDataTrack: track)
        }
    }

    func onTrackUnpublished(sid: String) {
        guard let room else { return }
        room.dataTrackDelegates.notify(label: { "room.didUnpublishDataTrack" }) {
            $0.room(room, didUnpublishDataTrack: sid)
        }
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
