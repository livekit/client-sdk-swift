/*
 * Copyright 2025 LiveKit
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

@globalActor
actor MetricsManager: Loggable {
    typealias Transport = @Sendable (Livekit_DataPacket) async throws -> Void
    var transport: Transport?

    static let shared = MetricsManager()

    private init() {}

    func sendUsing(_ transport: Transport?) {
        self.transport = transport
    }

    private func sendMetrics(from statistics: TrackStatistics) async {
        guard let transport else { return }

        var dataPacket = Livekit_DataPacket()
        dataPacket.kind = .reliable
        dataPacket.metrics = Livekit_MetricsBatch(statistics: statistics)
        do {
            try await transport(dataPacket)
        } catch {
            log("Failed to send metrics: \(error)", .warning)
        }
    }
}

private extension Livekit_MetricsBatch {
    init(statistics: TrackStatistics) {
        timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        addOutboundMetrics(from: statistics.outboundRtpStream)
    }

    mutating func addOutboundMetrics(from statistics: [OutboundRtpStreamStatistics]) {
        for s in statistics {
            print(s)
        }
    }

    func createMetricSample(timestamp: TimeInterval, value: Float) -> Livekit_MetricSample {
        var sample = Livekit_MetricSample()
        sample.timestampMs = Int64(timestamp * 1000)
        sample.value = value
        return sample
    }

    func createTimeSeriesForMetric() {}
}

extension MetricsManager: TrackDelegate {
    nonisolated func track(_: Track, didUpdateStatistics: TrackStatistics, simulcastStatistics _: [VideoCodec: TrackStatistics]) {
        Task(priority: .low) {
            await sendMetrics(from: didUpdateStatistics)
        }
    }
}
