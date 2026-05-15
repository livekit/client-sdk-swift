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
import LiveKit

/// A second SDK instance that acts as an echo participant for
/// data channel and RPC benchmarks.
///
/// Connects to the same room and echoes:
/// - Data channel messages back to the sender
/// - RPC calls back with the same payload
///
/// Records its own processing timestamps for overhead decomposition.
final class EchoParticipant: Sendable {
    let room: Room

    /// Processing timestamps: (receive time, echo sent time) in microseconds
    /// relative to an arbitrary monotonic epoch.
    struct ProcessingTimestamp {
        let receiveUs: Int64
        let echoSentUs: Int64
        var overheadUs: Int64 { echoSentUs - receiveUs }
    }

    private let _timestamps = StateSync<[ProcessingTimestamp]>([])
    // Strong reference to keep the delegate alive (MulticastDelegate uses weak references)
    private nonisolated(unsafe) var _echoDelegate: AnyObject?

    var processingTimestamps: [ProcessingTimestamp] {
        _timestamps.copy()
    }

    init() {
        room = Room()
    }

    /// Connect to the specified room and set up echo handlers.
    func connect(url: String, token: String) async throws {
        try await room.connect(url: url, token: token)
    }

    /// Register the echo RPC handler.
    ///
    /// - Parameter delay: Optional delay in nanoseconds to simulate processing (for BM-RPC-003)
    func registerEchoRpc(delay: UInt64 = 0) async throws {
        try await room.registerRpcMethod("echo") { data in
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            return data.payload
        }
    }

    /// Set up data echo handler that echoes received data back to the sender.
    func setupDataEcho() {
        let delegate = DataEchoDelegate(room: room, timestamps: _timestamps)
        _echoDelegate = delegate
        room.delegates.add(delegate: delegate)
    }

    func disconnect() async {
        await room.disconnect()
    }

    func clearTimestamps() {
        _timestamps.mutate { $0.removeAll() }
    }
}

/// Delegate that echoes data channel messages.
private final class DataEchoDelegate: NSObject, RoomDelegate, @unchecked Sendable {
    private let room: Room
    private let timestamps: StateSync<[EchoParticipant.ProcessingTimestamp]>

    init(room: Room, timestamps: StateSync<[EchoParticipant.ProcessingTimestamp]>) {
        self.room = room
        self.timestamps = timestamps
        super.init()
    }

    func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType _: EncryptionType) {
        let recvTime = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000)
        Task {
            try? await room.localParticipant.publish(
                data: data,
                options: .init(topic: topic)
            )
            let sentTime = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000)
            timestamps.mutate {
                $0.append(EchoParticipant.ProcessingTimestamp(
                    receiveUs: recvTime,
                    echoSentUs: sentTime
                ))
            }
        }
    }
}
