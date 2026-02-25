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

/// BM-DC: Data Channel Latency Benchmarks
///
/// Measures round-trip time for data sent through LiveKit's data channel
/// infrastructure between two SDK instances in the same room.
///
/// Variants:
/// - BM-DC-001: Reliable channel, 100 bytes
/// - BM-DC-002: Lossy channel, 100 bytes
/// - BM-DC-003: Reliable channel, 14,000 bytes

let dataChannelBenchmarks: @Sendable () -> Void = {
    let config = BenchmarkConfig.fromEnvironment()
    let tokenGen = TokenGenerator(apiKey: config.apiKey, apiSecret: config.apiSecret)

    // BM-DC-001: Reliable channel, small payload
    Benchmark(
        "BM-DC-001-Reliable-100B",
        configuration: .init(
            warmupIterations: 5,
            scalingFactor: .one,
            maxDuration: .seconds(300),
            maxIterations: 50
        )
    ) { benchmark in
        let roomName = "benchmark-dc-001-\(UUID().uuidString.prefix(8))"

        // Setup echo participant
        let echo = EchoParticipant()
        let echoToken = tokenGen.generate(roomName: roomName, identity: "bench-echo")
        try await echo.connect(url: config.url, token: echoToken)
        echo.setupDataEcho()

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

        // Setup data receive handler on sender to capture echo
        let echoReceiver = DataReceiveTracker()
        senderRoom.delegates.add(delegate: echoReceiver)

        let payload = Data(repeating: 0xAB, count: 100)

        for _ in benchmark.scaledIterations {
            await echoReceiver.reset()

            benchmark.startMeasurement()
            try await senderRoom.localParticipant.publish(
                data: payload,
                options: .init(topic: "benchmark", reliable: true)
            )

            // Wait for echo
            try await echoReceiver.waitForData(timeout: 5.0)
            benchmark.stopMeasurement()

            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // BM-DC-002: Lossy channel, small payload
    Benchmark(
        "BM-DC-002-Lossy-100B",
        configuration: .init(
            warmupIterations: 5,
            scalingFactor: .one,
            maxDuration: .seconds(300),
            maxIterations: 50
        )
    ) { benchmark in
        let roomName = "benchmark-dc-002-\(UUID().uuidString.prefix(8))"

        let echo = EchoParticipant()
        let echoToken = tokenGen.generate(roomName: roomName, identity: "bench-echo")
        try await echo.connect(url: config.url, token: echoToken)
        echo.setupDataEcho()

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

        let echoReceiver = DataReceiveTracker()
        senderRoom.delegates.add(delegate: echoReceiver)

        let payload = Data(repeating: 0xAB, count: 100)

        for _ in benchmark.scaledIterations {
            await echoReceiver.reset()

            benchmark.startMeasurement()
            try await senderRoom.localParticipant.publish(
                data: payload,
                options: .init(topic: "benchmark", reliable: false)
            )

            try await echoReceiver.waitForData(timeout: 5.0)
            benchmark.stopMeasurement()

            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // BM-DC-003: Reliable channel, large payload
    Benchmark(
        "BM-DC-003-Reliable-14KB",
        configuration: .init(
            warmupIterations: 5,
            scalingFactor: .one,
            maxDuration: .seconds(300),
            maxIterations: 50
        )
    ) { benchmark in
        let roomName = "benchmark-dc-003-\(UUID().uuidString.prefix(8))"

        let echo = EchoParticipant()
        let echoToken = tokenGen.generate(roomName: roomName, identity: "bench-echo")
        try await echo.connect(url: config.url, token: echoToken)
        echo.setupDataEcho()

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

        let echoReceiver = DataReceiveTracker()
        senderRoom.delegates.add(delegate: echoReceiver)

        let payload = Data(repeating: 0xAB, count: 14000)

        for _ in benchmark.scaledIterations {
            await echoReceiver.reset()

            benchmark.startMeasurement()
            try await senderRoom.localParticipant.publish(
                data: payload,
                options: .init(topic: "benchmark", reliable: true)
            )

            try await echoReceiver.waitForData(timeout: 5.0)
            benchmark.stopMeasurement()

            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}

/// Actor-based tracker for data received on a room, used to measure echo round-trip time.
actor DataReceiveTracker: RoomDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?

    func reset() {
        continuation = nil
    }

    func waitForData(timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                    Task { await self.setContinuation(cont) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BenchmarkError.timeout
            }
            // Wait for whichever finishes first
            try await group.next()
            group.cancelAll()
        }
    }

    private func setContinuation(_ cont: CheckedContinuation<Void, any Error>) {
        continuation = cont
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant?, didReceiveData _: Data, forTopic _: String, encryptionType _: EncryptionType) {
        Task { await resumeContinuation() }
    }

    private func resumeContinuation() {
        let c = continuation
        continuation = nil
        c?.resume()
    }
}

enum BenchmarkError: Error {
    case timeout
}
