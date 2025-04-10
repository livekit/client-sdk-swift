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

// MARK: - Trigger

extension MetricsManager: TrackDelegate {
    nonisolated func track(_: Track, didUpdateStatistics: TrackStatistics, simulcastStatistics _: [VideoCodec: TrackStatistics]) {
        Task(priority: .low) {
            await sendMetrics(from: didUpdateStatistics)
        }
    }
}

// MARK: - Actor

@globalActor
actor MetricsManager: Loggable {
    static let shared = MetricsManager()

    typealias Transport = @Sendable (Livekit_DataPacket) async throws -> Void
    var transport: Transport?

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
            log("Sending track metrics...", .trace)
            try await transport(dataPacket)
        } catch {
            log("Failed to send metrics: \(error)", .warning)
        }
    }
}

// MARK: - Statistics -> protobufs

private extension Livekit_MetricsBatch {
    init(statistics: TrackStatistics) {
        var strings = [String]()
        defer { strData = strings }

        addOutboundMetrics(from: statistics.outboundRtpStream, strings: &strings)
        addInboundMetrics(from: statistics.inboundRtpStream, strings: &strings)
    }

    mutating func addOutboundMetrics(from statistics: [OutboundRtpStreamStatistics], strings: inout [String]) {
        for stat in statistics {
            guard stat.kind == "video" else { continue }

            if let durations = stat.qualityLimitationDurations {
                addMetricIfPresent(durations.cpu, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationCpu, strings: &strings)
                addMetricIfPresent(durations.bandwidth, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationBandwidth, strings: &strings)
                addMetricIfPresent(durations.other, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationOther, strings: &strings)
            }
        }
    }

    mutating func addInboundMetrics(from statistics: [InboundRtpStreamStatistics], strings: inout [String]) {
        for stat in statistics {
            if stat.kind == "audio" {
                addMetricIfPresent(stat.concealedSamples, at: stat.timestamp, label: .clientAudioSubscriberConcealedSamples, strings: &strings)
                addMetricIfPresent(stat.concealmentEvents, at: stat.timestamp, label: .clientAudioSubscriberConcealmentEvents, strings: &strings)
                addMetricIfPresent(stat.silentConcealedSamples, at: stat.timestamp, label: .clientAudioSubscriberSilentConcealedSamples, strings: &strings)
            } else if stat.kind == "video" {
                addMetricIfPresent(stat.freezeCount, at: stat.timestamp, label: .clientVideoSubscriberFreezeCount, strings: &strings)
                addMetricIfPresent(stat.totalFreezesDuration, at: stat.timestamp, label: .clientVideoSubscriberTotalFreezeDuration, strings: &strings)
                addMetricIfPresent(stat.pauseCount, at: stat.timestamp, label: .clientVideoSubscriberPauseCount, strings: &strings)
                addMetricIfPresent(stat.totalPausesDuration, at: stat.timestamp, label: .clientVideoSubscriberTotalPausesDuration, strings: &strings)
            }

            // Common metrics
            addMetricIfPresent(stat.jitterBufferDelay, at: stat.timestamp, label: .clientSubscriberJitterBufferDelay, strings: &strings)
            addMetricIfPresent(stat.jitterBufferEmittedCount, at: stat.timestamp, label: .clientSubscriberJitterBufferEmittedCount, strings: &strings)
        }
    }

    mutating func addMetricIfPresent(
        _ value: (some Numeric)?,
        at timestamp: TimeInterval,
        label: Livekit_MetricLabel,
        strings: inout [String]
    ) {
        guard let floatValue = value?.floatValue else { return }

        let sample = createMetricSample(timestamp: timestamp, value: floatValue)
        let timeSeries = createTimeSeries(
            label: label,
            strings: &strings,
            samples: [sample]
        )
        self.timeSeries.append(timeSeries)
    }

    func createMetricSample(timestamp: TimeInterval, value: Float) -> Livekit_MetricSample {
        var sample = Livekit_MetricSample()
        sample.timestampMs = Int64(timestamp * 1000)
        sample.value = value
        return sample
    }

    func createTimeSeries(
        label: Livekit_MetricLabel,
        strings _: inout [String],
        samples: [Livekit_MetricSample]
    ) -> Livekit_TimeSeriesMetric {
        var timeSeries = Livekit_TimeSeriesMetric()
        timeSeries.label = UInt32(label.rawValue)
        timeSeries.samples = samples
        return timeSeries
    }

    func getOrCreateIndex(in array: inout [String], string: String) -> Int {
        let offset = Livekit_MetricLabel.predefinedMaxValue.rawValue
        if let index = array.firstIndex(of: string) {
            return index + offset
        }
        array.append(string)
        return array.count - 1 + offset
    }
}

// MARK: - Extensions

private extension Numeric {
    var floatValue: Float? {
        if let floatValue = self as? Float {
            return floatValue
        } else if let doubleValue = self as? Double {
            return Float(doubleValue)
        } else if let uint64Value = self as? UInt64 {
            return Float(uint64Value)
        } else if let uintValue = self as? UInt {
            return Float(uintValue)
        } else {
            assertionFailure("Cannot convert Numeric \(Self.self)")
            return nil
        }
    }
}
