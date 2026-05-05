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

// BM-CONN: Connection Time Benchmarks (25 iterations)
//
// Measures the time from `room.connect()` invocation to the room reaching
// `connected` state, decomposed into signaling, transport setup, and
// data channel phases via the shared `Tracing` spans.
//
// Variants:
// - BM-CONN-001: Dual PeerConnection, subscriber-primary (default)
// - BM-CONN-003: Single PeerConnection

private let dWs: BenchmarkMetric = .custom("D_WS_MS", polarity: .prefersSmaller, useScalingFactor: false)
private let dSignal: BenchmarkMetric = .custom("D_SIGNAL_MS", polarity: .prefersSmaller, useScalingFactor: false)
private let dTransport: BenchmarkMetric = .custom("D_TRANSPORT_MS", polarity: .prefersSmaller, useScalingFactor: false)
private let dIceDtls: BenchmarkMetric = .custom("D_ICE_DTLS_MS", polarity: .prefersSmaller, useScalingFactor: false)
private let dDc: BenchmarkMetric = .custom("D_DC_MS", polarity: .prefersSmaller, useScalingFactor: false)

let connectionBenchmarks: @Sendable () -> Void = {
    // BM-CONN-001: Dual PeerConnection, subscriber-primary (default)
    Benchmark(
        "BM-CONN-001-DualPC-SubscriberPrimary",
        configuration: .init(
            metrics: .default + [dWs, dSignal, dTransport, dIceDtls, dDc],
            timeUnits: .milliseconds,
            units: [dWs: .count, dSignal: .count, dTransport: .count, dIceDtls: .count, dDc: .count],
            warmupIterations: 5,
            scalingFactor: .one,
            maxDuration: .seconds(300),
            maxIterations: 25
        )
    ) { benchmark in
        let config = BenchmarkConfig.fromEnvironment()
        let tokenGen = TokenGenerator(apiKey: config.apiKey, apiSecret: config.apiSecret)

        for _ in benchmark.scaledIterations {
            let room = Room()
            let roomName = "benchmark-conn-001-\(UUID().uuidString.prefix(8))"
            let token = tokenGen.generate(roomName: roomName, identity: "bench-sender")

            benchmarkTracer.reset()

            benchmark.startMeasurement()
            try await room.connect(url: config.url, token: token)
            try? await room.waitUntilDataChannelsOpen()
            benchmark.stopMeasurement()

            // Extract fine-grained timestamps from the completed connect span
            if let span = benchmarkTracer.completedSpan("connect") {
                let s = span.splitMilliseconds
                let wsOpen = s["ws_open"] ?? 0
                let joinRecv = s["signal"] ?? s["join_recv"] ?? 0
                // Either side may initiate SDP — answer_sent in dual PC subscriber-primary
                // (server-initiated offer), offer_sent in single PC / publisher-primary.
                let sdpDispatched = s["answer_sent"] ?? s["offer_sent"]
                let pcConnected = s["pc_connected"] ?? 0
                let dcOpen = s["dc_open"]

                benchmark.measurement(dWs, Int(wsOpen))
                benchmark.measurement(dSignal, Int(joinRecv - wsOpen))
                benchmark.measurement(dTransport, Int(pcConnected - joinRecv))

                if let sdpDispatched {
                    benchmark.measurement(dIceDtls, Int(pcConnected - sdpDispatched))
                }
                if let dcOpen {
                    benchmark.measurement(dDc, Int(dcOpen - pcConnected))
                }
            }

            await room.disconnect()
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2s inter-run delay
        }
    }

    // BM-CONN-003: Single PeerConnection
    Benchmark(
        "BM-CONN-003-SinglePC",
        configuration: .init(
            metrics: .default + [dWs, dSignal, dTransport, dIceDtls, dDc],
            timeUnits: .milliseconds,
            units: [dWs: .count, dSignal: .count, dTransport: .count, dIceDtls: .count, dDc: .count],
            warmupIterations: 5,
            scalingFactor: .one,
            maxDuration: .seconds(300),
            maxIterations: 25
        )
    ) { benchmark in
        let config = BenchmarkConfig.fromEnvironment()
        let tokenGen = TokenGenerator(apiKey: config.apiKey, apiSecret: config.apiSecret)

        for _ in benchmark.scaledIterations {
            let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
            let roomName = "benchmark-conn-003-\(UUID().uuidString.prefix(8))"
            let token = tokenGen.generate(roomName: roomName, identity: "bench-sender")

            benchmarkTracer.reset()

            benchmark.startMeasurement()
            try await room.connect(url: config.url, token: token)
            try? await room.waitUntilDataChannelsOpen()
            benchmark.stopMeasurement()

            if let span = benchmarkTracer.completedSpan("connect") {
                let s = span.splitMilliseconds
                let wsOpen = s["ws_open"] ?? 0
                let joinRecv = s["signal"] ?? s["join_recv"] ?? 0
                let sdpDispatched = s["answer_sent"] ?? s["offer_sent"]
                let pcConnected = s["pc_connected"] ?? 0
                let dcOpen = s["dc_open"]

                benchmark.measurement(dWs, Int(wsOpen))
                benchmark.measurement(dSignal, Int(joinRecv - wsOpen))
                benchmark.measurement(dTransport, Int(pcConnected - joinRecv))

                if let sdpDispatched {
                    benchmark.measurement(dIceDtls, Int(pcConnected - sdpDispatched))
                }
                if let dcOpen {
                    benchmark.measurement(dDc, Int(dcOpen - pcConnected))
                }
            }

            await room.disconnect()
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2s inter-run delay
        }
    }
}
