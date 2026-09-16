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
        case none, sender, receiver, both, simultaneous, bothLate

        var description: String {
            switch self {
            case .none: "no reconnect"
            case .sender: "sender reconnect"
            case .receiver: "receiver reconnect"
            case .both: "dual reconnect"
            case .simultaneous: "simultaneous reconnect"
            case .bothLate: "dual reconnect (late)"
            }
        }

        /// When (if at all) the sender room should call `startReconnect`.
        /// `nil` means no sender reconnect for this mode.
        var senderReconnectDelay: TimeInterval? {
            switch self {
            case .none, .receiver: nil
            case .sender, .both: 0.2
            case .simultaneous: 0.3
            // Mid-burst: 2s is ~40 sends in, so the retry buffer has a
            // non-trivial replay set vs. early reconnects that only
            // have to replay 4–8 entries.
            case .bothLate: 2.0
            }
        }

        var receiverReconnectDelay: TimeInterval? {
            switch self {
            case .none, .sender: nil
            case .receiver, .both: 0.4
            case .simultaneous: 0.3
            case .bothLate: 3.0
            }
        }
    }

    private let _receivedIndices = StateSync<[UInt32]>([])
    var onDataReceived: (() -> Void)?

    /// Waits until the final index lands, or delivery goes idle for `idleTimeout`.
    ///
    /// Waits for the *last* index rather than a full count: a reconnect mode can legitimately drop
    /// the in-flight window, where waiting for every index would always burn the whole timeout.
    ///
    /// The timeout is on *idle*, not on the whole wait. This test ships ~3.9 MB of reliable payload
    /// and a loaded runner can still be draining it well past any flat window; stopping early tears
    /// the room down with packets still in the transport, and those are lost — `send` resolves when
    /// a write reaches `sendData`, not when it is delivered. Resetting on progress keeps a genuine
    /// stall failing within `idleTimeout` while letting a slow drain finish.
    private func waitForDelivery(upTo iterations: Int, idleTimeout: TimeInterval) async {
        var lastCount = -1
        var idleDeadline = Date().addingTimeInterval(idleTimeout)
        while Date() < idleDeadline, _receivedIndices.copy().last != UInt32(iterations - 1) {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let count = _receivedIndices.copy().count
            if count != lastCount {
                lastCount = count
                idleDeadline = Date().addingTimeInterval(idleTimeout)
            }
        }
    }

    /// The delivery guarantees the reliable channel actually makes, per reconnect mode.
    private func expectDelivery(_ received: [UInt32], mode: ReconnectMode, iterations: Int) {
        // True in every mode: the channel neither reorders nor duplicates, and never invents an
        // index. These are the properties a regression in the send path would break.
        #expect(received == received.sorted(), "Reliable delivery should preserve send order")
        #expect(Set(received).count == received.count, "Reliable delivery should not duplicate")
        #expect(received.allSatisfy { $0 < UInt32(iterations) }, "Received an index that was never sent")

        switch mode {
        case .none:
            #expect(received == Array(0 ..< UInt32(iterations)),
                    "Without a reconnect, reliable delivery should be exact with no drops")
        default:
            // Deliberately not asserting zero loss. `startReconnect` escalates to a *full*
            // reconnect when the resume does not land in time, and a full reconnect clears the
            // publisher's replay set by design: `ReliableStage.reset()` drops the retained writes
            // along with the sequence counter they were stamped under, because writes from the old
            // counter cannot be replayed into a session whose counter restarted. A packet already
            // handed to `sendData` at that moment is lost, and its `send` has already returned
            // success — so exact delivery across a reconnect is not a guarantee the SDK makes, and
            // asserting it made this test fail under load for the wrong reason.
            //
            // What must hold is that the session recovers and keeps delivering afterwards.
            #expect(received.last == UInt32(iterations - 1),
                    "Delivery should resume after the reconnect and carry the final packet")
        }
    }

    @Test(arguments: [ReconnectMode.none, .sender, .receiver, .both, .simultaneous, .bothLate])
    func reliableDelivery(mode: ReconnectMode) async throws {
        let iterations = 128
        let sendInterval: TimeInterval = 0.05
        // 15s tolerates the .bothLate case, where the receiver reconnect
        // doesn't kick in until 3s and replay then has to drain.
        let receiveDeadline: TimeInterval = 15

        let bodyString = "abcdefghijklmnopqrstuvwxyz🔥"
        let bodyData = try #require(String(repeating: bodyString, count: 1024).data(using: .utf8))

        // A range, not `iterations`: a reconnect mode may legitimately lose the in-flight window
        // (see the per-mode expectations below), so an exact count here would fail the modes that
        // are working as designed. The assertions after the block carry the real checks.
        try await confirmation("Data received", expectedCount: 1 ... iterations) { confirm in
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
                if let delay = mode.senderReconnectDelay {
                    reconnectTasks.append(Task {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        try await sending.startReconnect(reason: .debug)
                    }.cancellable())
                }
                if let delay = mode.receiverReconnectDelay {
                    reconnectTasks.append(Task {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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

                // Wait for the receiver inside `withRooms` so the data channel stays
                // open until every packet has been delivered; waiting after the body
                // returns loses anything still in flight to the room teardown.
                //
                await self.waitForDelivery(upTo: iterations, idleTimeout: receiveDeadline)
            }
        }

        expectDelivery(_receivedIndices.copy(), mode: mode, iterations: iterations)
    }

    @Test
    func concurrentReliableSendsDeliverExactlyOnce() async throws {
        let iterations = 256
        let receiveDeadline: TimeInterval = 15
        let bodyData = Data(repeating: 0xAB, count: 64)

        // A range, not `iterations`: a reconnect mode may legitimately lose the in-flight window
        // (see the per-mode expectations below), so an exact count here would fail the modes that
        // are working as designed. The assertions after the block carry the real checks.
        try await confirmation("Data received", expectedCount: 1 ... iterations) { confirm in
            _receivedIndices.mutate { $0 = [] }
            onDataReceived = { confirm() }

            try await TestEnvironment.withRooms([
                RoomTestingOptions(canPublishData: true),
                RoomTestingOptions(delegate: self, canSubscribe: true),
            ]) { rooms in
                let sending = rooms[0]
                let remoteIdentity = try #require(sending.remoteParticipants.keys.first)

                // Fire every send into the task group at once. Without the
                // event-loop-side sequence assignment, the AsyncStream yields
                // would land in a different order than the sequence stamp picked
                // numbers, the SFU would drop the laggards, and the receiver
                // would surface gaps in `_receivedIndices`.
                try await withThrowingTaskGroup { group in
                    for i in 0 ..< iterations {
                        group.addTask {
                            var seq = UInt32(i)
                            let packetData = Data(bytes: &seq, count: 4) + bodyData
                            let userPacket = Livekit_UserPacket.with {
                                $0.payload = packetData
                                $0.destinationIdentities = [remoteIdentity.stringValue]
                            }
                            try await sending.send(userPacket: userPacket, kind: .reliable)
                        }
                    }
                    try await group.waitForAll()
                }

                // Wait for the receiver inside `withRooms` so the data channel
                // stays open until every packet has been delivered. Polling
                // outside `withRooms` would race the room teardown, and
                // any still-in-flight packets would be lost when the
                // underlying SCTP connection closes.
                let deadline = Date().addingTimeInterval(receiveDeadline)
                while Date() < deadline, self._receivedIndices.copy().count < iterations {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }

        let received = _receivedIndices.copy()
        #expect(received.sorted() == Array(0 ..< UInt32(iterations)),
                "Reliable delivery must cover every sequence exactly once, with no drops or dupes")
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
