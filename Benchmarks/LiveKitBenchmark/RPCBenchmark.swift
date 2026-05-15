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

/// BM-RPC: RPC Latency Benchmarks (100 iterations)
///
/// Measures the round-trip latency of LiveKit's RPC mechanism from
/// `performRpc()` invocation through acknowledgment and response.
///
/// Uses two SDK instances: a sender that calls `performRpc()` and a receiver
/// that echoes the payload via a registered "echo" handler.
///
/// Payload tiers based on real LiveKit use cases:
/// - 200B: Chat messages, cursor tracking, presence, typing indicators
/// - 4KB: Annotation strokes, game state deltas, rich metadata, AI token chunks
/// - 15,359B: Max boundary (MAX_RPC_PAYLOAD_BYTES - 1), file transfer chunks, large state sync
///
/// Delay scales with payload size to isolate framework overhead from handler time:
/// - 50ms: Small/fast lookup
/// - 100ms: Medium/DB query
/// - 200ms: Large/external API
///
/// Variants:
/// - BM-RPC-001: 200 bytes, no delay
/// - BM-RPC-002: 4,096 bytes, no delay
/// - BM-RPC-003: 15,359 bytes (max payload), no delay
/// - BM-RPC-004: 200 bytes, 50ms delay
/// - BM-RPC-005: 4,096 bytes, 100ms delay
/// - BM-RPC-006: 15,359 bytes (max payload), 200ms delay

let rpcBenchmarks: @Sendable () -> Void = {
    registerRpcBenchmark(name: "BM-RPC-001-200B", payloadSize: 200, delay: 0)
    registerRpcBenchmark(name: "BM-RPC-002-4KB", payloadSize: 4096, delay: 0)
    registerRpcBenchmark(name: "BM-RPC-003-MaxPayload", payloadSize: 15359, delay: 0)
    registerRpcBenchmark(name: "BM-RPC-004-200B-50ms", payloadSize: 200, delay: 50_000_000)
    registerRpcBenchmark(name: "BM-RPC-005-4KB-100ms", payloadSize: 4096, delay: 100_000_000)
    registerRpcBenchmark(name: "BM-RPC-006-MaxPayload-200ms", payloadSize: 15359, delay: 200_000_000)
}

private func registerRpcBenchmark(
    name: String,
    payloadSize: Int,
    delay: UInt64
) {
    nonisolated(unsafe) var senderRoom: Room?
    nonisolated(unsafe) var echo: EchoParticipant?

    Benchmark(
        name,
        closure: { benchmark in
            guard let senderRoom else {
                fatalError("Setup not completed for \(name)")
            }

            let payload = String(repeating: "x", count: payloadSize)

            for _ in benchmark.scaledIterations {
                benchmark.startMeasurement()
                let response = try await senderRoom.localParticipant.performRpc(
                    destinationIdentity: Participant.Identity(from: "bench-echo"),
                    method: "echo",
                    payload: payload
                )
                benchmark.stopMeasurement()

                precondition(response == payload, "RPC echo payload mismatch")

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
            try await echoParticipant.registerEchoRpc(delay: delay)

            let sender = Room()
            let senderToken = tokenGen.generate(roomName: roomName, identity: "bench-sender")
            try await sender.connect(url: config.url, token: senderToken)

            try await Task.sleep(nanoseconds: 1_000_000_000)

            senderRoom = sender
            echo = echoParticipant
        },
        teardown: {
            if let room = senderRoom { await room.disconnect() }
            if let e = echo { await e.disconnect() }
            senderRoom = nil
            echo = nil
        }
    )
}
