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
    private var transport: Transport?
    private var identity: Participant.Identity?

    private var lastSentHash: Int?

    private init() {}

    func sendUsing(identity: Participant.Identity?, transport: Transport?) {
        self.transport = transport
        self.identity = identity
    }

    private func sendMetrics(from statistics: TrackStatistics) async {
        guard let transport else { return }
        let hash = statistics.hashValue
        guard hash != lastSentHash else { return }

        var dataPacket = Livekit_DataPacket()
        dataPacket.kind = .reliable
        dataPacket.metrics = Livekit_MetricsBatch(statistics: statistics)
        do {
            log("Sending track metrics...", .trace)
            try await transport(dataPacket)
            lastSentHash = hash
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
        addRemoteInboundMetrics(from: statistics.remoteInboundRtpStream, strings: &strings)
        addRemoteOutboundMetrics(from: statistics.remoteOutboundRtpStream, strings: &strings)
    }

    mutating func addOutboundMetrics(from statistics: [OutboundRtpStreamStatistics], strings: inout [String]) {
        for stat in statistics where stat.kind == "video" {
            if let durations = stat.qualityLimitationDurations {
                addMetric(durations.cpu, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationCpu, strings: &strings)
                addMetric(durations.bandwidth, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationBandwidth, strings: &strings)
                addMetric(durations.other, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationOther, strings: &strings)
            }
        }
    }

    mutating func addInboundMetrics(from statistics: [InboundRtpStreamStatistics], strings: inout [String]) {
        for stat in statistics {
            if stat.kind == "audio" {
                addMetric(stat.concealedSamples, at: stat.timestamp, label: .clientAudioSubscriberConcealedSamples, strings: &strings)
                addMetric(stat.concealmentEvents, at: stat.timestamp, label: .clientAudioSubscriberConcealmentEvents, strings: &strings)
                addMetric(stat.silentConcealedSamples, at: stat.timestamp, label: .clientAudioSubscriberSilentConcealedSamples, strings: &strings)
            } else if stat.kind == "video" {
                addMetric(stat.freezeCount, at: stat.timestamp, label: .clientVideoSubscriberFreezeCount, strings: &strings)
                addMetric(stat.totalFreezesDuration, at: stat.timestamp, label: .clientVideoSubscriberTotalFreezeDuration, strings: &strings)
                addMetric(stat.pauseCount, at: stat.timestamp, label: .clientVideoSubscriberPauseCount, strings: &strings)
                addMetric(stat.totalPausesDuration, at: stat.timestamp, label: .clientVideoSubscriberTotalPausesDuration, strings: &strings)
            }

            // Common metrics
            addMetric(stat.jitterBufferDelay, at: stat.timestamp, label: .clientSubscriberJitterBufferDelay, strings: &strings)
            addMetric(stat.jitterBufferEmittedCount, at: stat.timestamp, label: .clientSubscriberJitterBufferEmittedCount, strings: &strings)
        }
    }

    mutating func addRemoteInboundMetrics(from statistics: [RemoteInboundRtpStreamStatistics], strings: inout [String]) {
        for stat in statistics {
            addMetric(stat.roundTripTime, at: stat.timestamp, label: .subscriberRtt, strings: &strings)
        }
    }

    mutating func addRemoteOutboundMetrics(from statistics: [RemoteOutboundRtpStreamStatistics], strings: inout [String]) {
        for stat in statistics {
            addMetric(stat.roundTripTime, at: stat.timestamp, label: .publisherRtt, strings: &strings)
        }
    }

    mutating func addMetric(
        _ value: (some Numeric)?,
        at timestamp: TimeInterval,
        label: Livekit_MetricLabel,
        strings: inout [String]
    ) {
        guard let floatValue = value?.floatValue else { return }
        guard floatValue != .zero else { return }

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

    func getOrCreateIndex(in array: inout [String], string: String) -> UInt32 {
        let offset = Livekit_MetricLabel.predefinedMaxValue.rawValue
        if let index = array.firstIndex(of: string) {
            return UInt32(index + offset)
        }
        array.append(string)
        return UInt32(array.count - 1 + offset)
    }
}

// MARK: - Extensions

private extension Numeric {
    var floatValue: Float? {
        if let integer = self as? any BinaryInteger {
            return Float(integer)
        } else if let floatingPoint = self as? any BinaryFloatingPoint {
            return Float(floatingPoint)
        } else {
            assertionFailure("Cannot convert Numeric \(Self.self)")
            return nil
        }
    }
}
