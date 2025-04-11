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
            await sendMetrics(statistics: didUpdateStatistics)
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

    private func sendMetrics(statistics: TrackStatistics) async {
        guard let transport else { return }
        let hash = statistics.hashValue
        guard hash != lastSentHash else { return }

        var dataPacket = Livekit_DataPacket()
        dataPacket.kind = .reliable
        dataPacket.metrics = Livekit_MetricsBatch(statistics: statistics, identity: identity)
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
    init(statistics: TrackStatistics, identity: Participant.Identity?) {
        var strings = [String]()
        defer { strData = strings }

        addOutboundMetrics(from: statistics.outboundRtpStream, strings: &strings, identity: identity)
        addInboundMetrics(from: statistics.inboundRtpStream, strings: &strings, identity: identity)
        addRemoteInboundMetrics(from: statistics.remoteInboundRtpStream, strings: &strings, identity: identity)
        addRemoteOutboundMetrics(from: statistics.remoteOutboundRtpStream, strings: &strings, identity: identity)
    }

    mutating func addOutboundMetrics(from statistics: [OutboundRtpStreamStatistics], strings: inout [String], identity: Participant.Identity?) {
        for stat in statistics where stat.kind == "video" {
            if let durations = stat.qualityLimitationDurations {
                addMetric(durations.cpu, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationCpu, strings: &strings, identity: identity, rid: stat.rid)
                addMetric(durations.bandwidth, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationBandwidth, strings: &strings, identity: identity, rid: stat.rid)
                addMetric(durations.other, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationOther, strings: &strings, identity: identity, rid: stat.rid)
            }
        }
    }

    mutating func addInboundMetrics(from statistics: [InboundRtpStreamStatistics], strings: inout [String], identity: Participant.Identity?) {
        for stat in statistics {
            if stat.kind == "audio" {
                addMetric(stat.concealedSamples, at: stat.timestamp, label: .clientAudioSubscriberConcealedSamples, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.concealmentEvents, at: stat.timestamp, label: .clientAudioSubscriberConcealmentEvents, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.silentConcealedSamples, at: stat.timestamp, label: .clientAudioSubscriberSilentConcealedSamples, strings: &strings, identity: identity, sid: stat.trackIdentifier)
            } else if stat.kind == "video" {
                addMetric(stat.freezeCount, at: stat.timestamp, label: .clientVideoSubscriberFreezeCount, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.totalFreezesDuration, at: stat.timestamp, label: .clientVideoSubscriberTotalFreezeDuration, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.pauseCount, at: stat.timestamp, label: .clientVideoSubscriberPauseCount, strings: &strings, identity: identity, sid: stat.trackIdentifier)
                addMetric(stat.totalPausesDuration, at: stat.timestamp, label: .clientVideoSubscriberTotalPausesDuration, strings: &strings, identity: identity, sid: stat.trackIdentifier)
            }

            // Common metrics
            addMetric(stat.jitterBufferDelay, at: stat.timestamp, label: .clientSubscriberJitterBufferDelay, strings: &strings, identity: identity, sid: stat.trackIdentifier)
            addMetric(stat.jitterBufferEmittedCount, at: stat.timestamp, label: .clientSubscriberJitterBufferEmittedCount, strings: &strings, identity: identity, sid: stat.trackIdentifier)
        }
    }

    mutating func addRemoteInboundMetrics(from statistics: [RemoteInboundRtpStreamStatistics], strings: inout [String], identity: Participant.Identity?) {
        for stat in statistics {
            addMetric(stat.roundTripTime, at: stat.timestamp, label: .subscriberRtt, strings: &strings, identity: identity)
        }
    }

    mutating func addRemoteOutboundMetrics(from statistics: [RemoteOutboundRtpStreamStatistics], strings: inout [String], identity: Participant.Identity?) {
        for stat in statistics {
            addMetric(stat.roundTripTime, at: stat.timestamp, label: .publisherRtt, strings: &strings, identity: identity)
        }
    }

    mutating func addMetric(
        _ value: (some Numeric)?,
        at timestamp: TimeInterval,
        label: Livekit_MetricLabel,
        strings: inout [String],
        identity: Participant.Identity? = nil,
        sid: String? = nil,
        rid: String? = nil
    ) {
        guard let floatValue = value?.floatValue else { return }
        guard floatValue != .zero else { return }

        let sample = createMetricSample(timestamp: timestamp, value: floatValue)
        let timeSeries = createTimeSeries(
            label: label,
            strings: &strings,
            samples: [sample],
            identity: identity,
            sid: sid,
            rid: rid
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
        strings: inout [String],
        samples: [Livekit_MetricSample],
        identity: Participant.Identity? = nil,
        sid: String? = nil,
        rid: String? = nil
    ) -> Livekit_TimeSeriesMetric {
        var timeSeries = Livekit_TimeSeriesMetric()
        timeSeries.label = UInt32(label.rawValue)
        timeSeries.samples = samples

        if let identity {
            timeSeries.participantIdentity = getOrCreateIndex(in: &strings, string: identity.stringValue)
        }
        if let sid {
            timeSeries.trackSid = getOrCreateIndex(in: &strings, string: sid)
        }
        if let rid {
            timeSeries.rid = getOrCreateIndex(in: &strings, string: rid)
        }

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
