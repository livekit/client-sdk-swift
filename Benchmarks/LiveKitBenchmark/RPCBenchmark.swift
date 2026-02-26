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

/// BM-RPC: RPC Latency Benchmarks
///
/// Measures the round-trip latency of LiveKit's RPC mechanism from
/// `performRpc()` invocation through acknowledgment and response.
///
/// Uses two SDK instances: a sender that calls `performRpc()` and a receiver
/// that echoes the payload via a registered "echo" handler.
///
/// Variants:
/// - BM-RPC-001: 100 bytes, no delay
/// - BM-RPC-002: 14,000 bytes, no delay
/// - BM-RPC-003: 100 bytes, 50ms simulated processing delay

let rpcBenchmarks: @Sendable () -> Void = {
    registerRpcBenchmark(name: "BM-RPC-001-100B", payloadSize: 100, delay: 0)
    registerRpcBenchmark(name: "BM-RPC-002-14KB", payloadSize: 14000, delay: 0)
    registerRpcBenchmark(name: "BM-RPC-003-100B-50ms", payloadSize: 100, delay: 50_000_000)
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
