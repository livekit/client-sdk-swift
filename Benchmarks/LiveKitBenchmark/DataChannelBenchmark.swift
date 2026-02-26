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

import Benchmark
import Foundation
import LiveKit

/// BM-DC: Data Channel Latency Benchmarks (100 iterations)
///
/// Measures round-trip time for data sent through LiveKit's data channel
/// infrastructure between two SDK instances in the same room.
///
/// Payload tiers based on real LiveKit use cases:
/// - 200B: Chat messages, cursor tracking, presence, typing indicators
/// - 4KB: Annotation strokes, game state deltas, rich metadata, AI token chunks
/// - 15,359B: Max boundary (MAX_RPC_PAYLOAD_BYTES - 1), file transfer chunks, large state sync
///
/// Variants:
/// - BM-DC-001: Reliable channel, 200 bytes
/// - BM-DC-002: Reliable channel, 4,096 bytes
/// - BM-DC-003: Reliable channel, 15,359 bytes (max payload)
/// - BM-DC-004: Lossy channel, 200 bytes
/// - BM-DC-005: Lossy channel, 4,096 bytes
/// - BM-DC-006: Lossy channel, 15,359 bytes (max payload)

let dataChannelBenchmarks: @Sendable () -> Void = {
    registerDataChannelBenchmark(name: "BM-DC-001-Reliable-200B", payloadSize: 200, reliable: true)
    registerDataChannelBenchmark(name: "BM-DC-002-Reliable-4KB", payloadSize: 4096, reliable: true)
    registerDataChannelBenchmark(name: "BM-DC-003-Reliable-MaxPayload", payloadSize: 15359, reliable: true)
    registerDataChannelBenchmark(name: "BM-DC-004-Lossy-200B", payloadSize: 200, reliable: false)
    registerDataChannelBenchmark(name: "BM-DC-005-Lossy-4KB", payloadSize: 4096, reliable: false)
    registerDataChannelBenchmark(name: "BM-DC-006-Lossy-MaxPayload", payloadSize: 15359, reliable: false)
}

private func registerDataChannelBenchmark(
    name: String,
    payloadSize: Int,
    reliable: Bool
) {
    nonisolated(unsafe) var senderRoom: Room?
    nonisolated(unsafe) var echo: EchoParticipant?
    nonisolated(unsafe) var echoReceiver: DataReceiveTracker?

    Benchmark(
        name,
        closure: { benchmark in
            guard let senderRoom, let echoReceiver else {
                fatalError("Setup not completed for \(name)")
            }

            let payload = Data(repeating: 0xAB, count: payloadSize)

            for _ in benchmark.scaledIterations {
                benchmark.startMeasurement()
                try await senderRoom.localParticipant.publish(
                    data: payload,
                    options: .init(topic: "benchmark", reliable: reliable)
                )
                try await echoReceiver.waitForData(timeout: 5.0)
                benchmark.stopMeasurement()

                try await Task.sleep(nanoseconds: 500_000_000)
            }
        },
        setup: {
            let config = BenchmarkConfig.fromEnvironment()
            let tokenGen = TokenGenerator(apiKey: config.apiKey, apiSecret: config.apiSecret)
            let roomName = "benchmark-\(name.lowercased())-\(UUID().uuidString.prefix(8))"

            let echoParticipant = EchoParticipant()
            let echoToken = tokenGen.generate(roomName: roomName, identity: "bench-echo")
            try await echoParticipant.connect(url: config.url, token: echoToken)
            echoParticipant.setupDataEcho()

            let sender = Room()
            let senderToken = tokenGen.generate(roomName: roomName, identity: "bench-sender")
            try await sender.connect(url: config.url, token: senderToken)

            try await Task.sleep(nanoseconds: 1_000_000_000)

            let tracker = DataReceiveTracker()
            sender.delegates.add(delegate: tracker)

            senderRoom = sender
            echo = echoParticipant
            echoReceiver = tracker
        },
        teardown: {
            if let room = senderRoom { await room.disconnect() }
            if let e = echo { await e.disconnect() }
            senderRoom = nil
            echo = nil
            echoReceiver = nil
        }
    )
}

/// Tracks data received on a room, used to measure echo round-trip time.
/// Uses AsyncStream to avoid race conditions between data arrival and waiting.
final class DataReceiveTracker: NSObject, RoomDelegate, @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    override init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
        super.init()
    }

    func waitForData(timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = self.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BenchmarkError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func room(_: Room, participant _: RemoteParticipant?, didReceiveData _: Data, forTopic _: String, encryptionType _: EncryptionType) {
        continuation.yield()
    }
}

enum BenchmarkError: Error {
    case timeout
}
