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

/// BM-PUB: Track Publishing Latency Benchmarks
///
/// Measures the time from `publish(track:)` invocation through device
/// initialization, server acknowledgment, and renegotiation.
///
/// Note: These benchmarks use synthetic audio tracks to avoid hardware
/// dependencies in CI. Results are labeled accordingly.
///
/// Variants:
/// - BM-PUB-001: Audio track (synthetic)
/// - BM-PUB-003: Audio track, pre-warmed capture device

let trackPublishBenchmarks: @Sendable () -> Void = {
    let config = BenchmarkConfig.fromEnvironment()
    let tokenGen = TokenGenerator(apiKey: config.apiKey, apiSecret: config.apiSecret)

    // BM-PUB-001: Audio track publish (full, including device init)
    Benchmark(
        "BM-PUB-001-Audio",
        configuration: .init(
            warmupIterations: 5,
            scalingFactor: .one,
            maxDuration: .seconds(300),
            maxIterations: 30
        )
    ) { benchmark in
        // Setup: connect once, reuse the room for all iterations
        let room = Room()
        let roomName = "benchmark-pub-001-\(UUID().uuidString.prefix(8))"
        let token = tokenGen.generate(roomName: roomName, identity: "bench-publisher")
        try await room.connect(url: config.url, token: token)

        defer {
            Task { await room.disconnect() }
        }

        for _ in benchmark.scaledIterations {
            let audioTrack = LocalAudioTrack.createTrack()

            benchmark.startMeasurement()
            let publication = try await room.localParticipant.publish(audioTrack: audioTrack)
            benchmark.stopMeasurement()

            try await room.localParticipant.unpublish(publication: publication)
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // BM-PUB-003: Audio track, pre-warmed capture device
    Benchmark(
        "BM-PUB-003-Audio-PreWarmed",
        configuration: .init(
            warmupIterations: 5,
            scalingFactor: .one,
            maxDuration: .seconds(300),
            maxIterations: 30
        )
    ) { benchmark in
        let room = Room()
        let roomName = "benchmark-pub-003-\(UUID().uuidString.prefix(8))"
        let token = tokenGen.generate(roomName: roomName, identity: "bench-publisher")
        try await room.connect(url: config.url, token: token)

        defer {
            Task { await room.disconnect() }
        }

        for _ in benchmark.scaledIterations {
            // Pre-warm: start the track before measurement
            let audioTrack = LocalAudioTrack.createTrack()
            try await audioTrack.start()

            benchmark.startMeasurement()
            let publication = try await room.localParticipant.publish(audioTrack: audioTrack)
            benchmark.stopMeasurement()

            try await room.localParticipant.unpublish(publication: publication)
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
