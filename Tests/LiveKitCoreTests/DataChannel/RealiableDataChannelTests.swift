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
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.serialized, .tags(.dataChannel, .e2e)) final class RealiableDataChannelTests: @unchecked Sendable {
    enum ReconnectMode: CustomStringConvertible {
        case none, sender, receiver, both

        var description: String {
            switch self {
            case .none: "no reconnect"
            case .sender: "sender reconnect"
            case .receiver: "receiver reconnect"
            case .both: "dual reconnect"
            }
        }

        var reconnectsSender: Bool { self == .sender || self == .both }
        var reconnectsReceiver: Bool { self == .receiver || self == .both }
    }

    private let _receivedIndices = StateSync<[UInt32]>([])
    var onDataReceived: (() -> Void)?

    @Test(arguments: [ReconnectMode.none, .sender, .receiver, .both])
    func reliableDelivery(mode: ReconnectMode) async throws {
        let iterations = 128
        let sendInterval: TimeInterval = 0.05
        let senderReconnectDelay: TimeInterval = 0.2
        let receiverReconnectDelay: TimeInterval = 0.4
        let receiveDeadline: TimeInterval = 10

        let bodyString = "abcdefghijklmnopqrstuvwxyz🔥"
        let bodyData = try #require(String(repeating: bodyString, count: 1024).data(using: .utf8))

        try await confirmation("Data received", expectedCount: iterations) { confirm in
            self._receivedIndices.mutate { $0 = [] }
            self.onDataReceived = { confirm() }

            try await TestEnvironment.withRooms([
                RoomTestingOptions(canPublishData: true),
                RoomTestingOptions(delegate: self, canSubscribe: true),
            ]) { rooms in
                let sending = rooms[0]
                let receiving = rooms[1]
                let remoteIdentity = try #require(sending.remoteParticipants.keys.first)

                var reconnectTasks: [AnyTaskCancellable] = []
                if mode.reconnectsSender {
                    reconnectTasks.append(Task {
                        try await Task.sleep(nanoseconds: UInt64(senderReconnectDelay * 1_000_000_000))
                        try await sending.startReconnect(reason: .debug)
                    }.cancellable())
                }
                if mode.reconnectsReceiver {
                    reconnectTasks.append(Task {
                        try await Task.sleep(nanoseconds: UInt64(receiverReconnectDelay * 1_000_000_000))
                        try await receiving.startReconnect(reason: .debug)
                    }.cancellable())
                }
                defer { reconnectTasks.forEach { $0.cancel() } }

                for i in 0 ..< iterations {
                    // 4-byte LE sequence prefix lets the receiver assert
                    // exact ordering — a size-only check would pass even
                    // if packets arrived reordered or with dupes.
                    var seq = UInt32(i)
                    let packetData = Data(bytes: &seq, count: 4) + bodyData
                    let userPacket = Livekit_UserPacket.with {
                        $0.payload = packetData
                        $0.destinationIdentities = [remoteIdentity.stringValue]
                    }

                    try await sending.send(userPacket: userPacket, kind: .reliable)
                    try await Task.sleep(nanoseconds: UInt64(sendInterval * 1_000_000_000))
                }
            }

            // `withRooms` tears the rooms down once its body returns, but
            // the last few deliveries may still be in flight. Poll until
            // all confirms have fired (or the deadline expires) so we
            // don't end the confirmation body prematurely.
            let deadline = Date().addingTimeInterval(receiveDeadline)
            while Date() < deadline, self._receivedIndices.copy().count < iterations {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        let received = _receivedIndices.copy()
        #expect(received == Array(0 ..< UInt32(iterations)),
                "Reliable delivery should be exact and in send order, with no dupes or drops")
    }
}

extension RealiableDataChannelTests: RoomDelegate {
    func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic _: String, encryptionType _: EncryptionType) {
        guard data.count >= 4 else { return }
        let seq = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        _receivedIndices.mutate { $0.append(seq) }
        onDataReceived?()
    }
}
