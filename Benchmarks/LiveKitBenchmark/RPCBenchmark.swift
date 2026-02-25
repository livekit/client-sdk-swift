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
    let config = BenchmarkConfig.fromEnvironment()
    let tokenGen = TokenGenerator(apiKey: config.apiKey, apiSecret: config.apiSecret)

    // BM-RPC-001: Small payload, no delay
    Benchmark(
        "BM-RPC-001-100B",
        configuration: .init(
            warmupIterations: 5,
            scalingFactor: .one,
            maxDuration: .seconds(300),
            maxIterations: 50
        )
    ) { benchmark in
        let roomName = "benchmark-rpc-001-\(UUID().uuidString.prefix(8))"

        // Setup echo participant with RPC handler
        let echo = EchoParticipant()
        let echoToken = tokenGen.generate(roomName: roomName, identity: "bench-echo")
        try await echo.connect(url: config.url, token: echoToken)
        try await echo.registerEchoRpc(delay: 0)

        // Setup sender
        let senderRoom = Room()
        let senderToken = tokenGen.generate(roomName: roomName, identity: "bench-sender")
        try await senderRoom.connect(url: config.url, token: senderToken)

        // Wait for both participants to be ready
        try await Task.sleep(nanoseconds: 1_000_000_000)

        defer {
            Task {
                await senderRoom.disconnect()
                await echo.disconnect()
            }
        }

        // Generate payload: 100 bytes as a string
        let payload = String(repeating: "x", count: 100)

        for _ in benchmark.scaledIterations {
            benchmark.startMeasurement()
            let response = try await senderRoom.localParticipant.performRpc(
                destinationIdentity: Participant.Identity(from: "bench-echo"),
                method: "echo",
                payload: payload
            )
            benchmark.stopMeasurement()

            // Verify echo correctness
            precondition(response == payload, "RPC echo payload mismatch")

            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // BM-RPC-002: Large payload, no delay
    Benchmark(
        "BM-RPC-002-14KB",
        configuration: .init(
            warmupIterations: 5,
            scalingFactor: .one,
            maxDuration: .seconds(300),
            maxIterations: 50
        )
    ) { benchmark in
        let roomName = "benchmark-rpc-002-\(UUID().uuidString.prefix(8))"

        let echo = EchoParticipant()
        let echoToken = tokenGen.generate(roomName: roomName, identity: "bench-echo")
        try await echo.connect(url: config.url, token: echoToken)
        try await echo.registerEchoRpc(delay: 0)

        let senderRoom = Room()
        let senderToken = tokenGen.generate(roomName: roomName, identity: "bench-sender")
        try await senderRoom.connect(url: config.url, token: senderToken)

        try await Task.sleep(nanoseconds: 1_000_000_000)

        defer {
            Task {
                await senderRoom.disconnect()
                await echo.disconnect()
            }
        }

        // 14,000 bytes — near MAX_RPC_PAYLOAD_BYTES (15,360)
        let payload = String(repeating: "x", count: 14000)

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
    }

    // BM-RPC-003: Small payload, 50ms simulated processing delay
    Benchmark(
        "BM-RPC-003-100B-50ms",
        configuration: .init(
            warmupIterations: 5,
            scalingFactor: .one,
            maxDuration: .seconds(300),
            maxIterations: 50
        )
    ) { benchmark in
        let roomName = "benchmark-rpc-003-\(UUID().uuidString.prefix(8))"

        let echo = EchoParticipant()
        let echoToken = tokenGen.generate(roomName: roomName, identity: "bench-echo")
        try await echo.connect(url: config.url, token: echoToken)
        // 50ms delay = 50_000_000 nanoseconds
        try await echo.registerEchoRpc(delay: 50_000_000)

        let senderRoom = Room()
        let senderToken = tokenGen.generate(roomName: roomName, identity: "bench-sender")
        try await senderRoom.connect(url: config.url, token: senderToken)

        try await Task.sleep(nanoseconds: 1_000_000_000)

        defer {
            Task {
                await senderRoom.disconnect()
                await echo.disconnect()
            }
        }

        let payload = String(repeating: "x", count: 100)

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
    }
}
