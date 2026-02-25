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

/// BM-CONN: Connection Time Benchmarks
///
/// Measures the time from `room.connect()` invocation to the room reaching
/// `connected` state, decomposed into signaling, transport setup, and
/// data channel phases via the shared ``Stopwatch`` spans.
///
/// Variants:
/// - BM-CONN-001: Dual PeerConnection, subscriber-primary (default)
/// - BM-CONN-003: Single PeerConnection

let connectionBenchmarks: @Sendable () -> Void = {
    let config = BenchmarkConfig.fromEnvironment()
    let tokenGen = TokenGenerator(apiKey: config.apiKey, apiSecret: config.apiSecret)

    // BM-CONN-001: Dual PeerConnection, subscriber-primary (default)
    Benchmark(
        "BM-CONN-001-DualPC-SubscriberPrimary"
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let room = Room()
            let roomName = "benchmark-conn-001-\(UUID().uuidString.prefix(8))"
            let token = tokenGen.generate(roomName: roomName, identity: "bench-sender")

            benchmarkStopwatch.reset()

            benchmark.startMeasurement()
            try await room.connect(url: config.url, token: token)
            benchmark.stopMeasurement()

            // Extract fine-grained timestamps from the completed connect span
            if let span = benchmarkStopwatch.completedSpan("connect") {
                let splits = span.splitMicroseconds
                benchmark.measurement(.custom("D_SIGNAL", polarity: .prefersSmaller, useScalingFactor: false),
                                      Int(splits["signal"] ?? splits["join_recv"] ?? 0))
                benchmark.measurement(.custom("D_TRANSPORT", polarity: .prefersSmaller, useScalingFactor: false),
                                      Int(splits["pc_connected"].map { $0 - (splits["join_recv"] ?? 0) } ?? 0))
            }

            await room.disconnect()
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2s inter-run delay
        }
    }

    // BM-CONN-003: Single PeerConnection
    Benchmark(
        "BM-CONN-003-SinglePC"
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let room = Room()
            let roomName = "benchmark-conn-003-\(UUID().uuidString.prefix(8))"
            let token = tokenGen.generate(roomName: roomName, identity: "bench-sender")

            // TODO: Enable single PC mode when RoomOptions supports it.
            // let roomOptions = RoomOptions(singlePeerConnection: true)
            #warning("BM-CONN-003: singlePeerConnection option not yet available in RoomOptions")

            benchmarkStopwatch.reset()

            benchmark.startMeasurement()
            try await room.connect(url: config.url, token: token)
            benchmark.stopMeasurement()

            if let span = benchmarkStopwatch.completedSpan("connect") {
                let splits = span.splitMicroseconds
                benchmark.measurement(.custom("D_SIGNAL", polarity: .prefersSmaller, useScalingFactor: false),
                                      Int(splits["signal"] ?? splits["join_recv"] ?? 0))
                benchmark.measurement(.custom("D_TRANSPORT", polarity: .prefersSmaller, useScalingFactor: false),
                                      Int(splits["pc_connected"].map { $0 - (splits["join_recv"] ?? 0) } ?? 0))
            }

            await room.disconnect()
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
