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
import OrderedCollections

// MARK: - Triggers

extension MetricsManager: RoomDelegate {
    nonisolated func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        guard let track = publication.track else { return }
        Task { await register(track: track, in: room, localParticipant: participant) }
    }

    nonisolated func room(_: Room, participant _: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        guard let track = publication.track else { return }
        Task { await unregister(track: track) }
    }

    nonisolated func room(_ room: Room, participant _: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track else { return }
        Task { await register(track: track, in: room, localParticipant: room.localParticipant) } // send from local participant
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        guard let track = publication.track else { return }
        Task { await unregister(track: track) }
    }
}

extension MetricsManager: TrackDelegate {
    // If Track.reportStatistics is disabled, this delegate method will not be called.
    nonisolated func track(_ track: Track, didUpdateStatistics: TrackStatistics, simulcastStatistics _: [VideoCodec: TrackStatistics]) {
        Task(priority: .low) {
            await sendMetrics(track: track, statistics: didUpdateStatistics)
        }
    }
}

// MARK: - Actor

/// An actor that converts track statistics into metrics and sends them to the server as data packets.
actor MetricsManager: Loggable {
    private typealias Transport = @Sendable (Livekit_DataPacket) async throws -> Void
    private struct TrackProperties {
        let identity: LocalParticipant.Identity?
        let transport: Transport
        var lastSentHash: Int?
    }

    private var trackProperties: [Track.Sid: TrackProperties] = [:]

    init() {}

    func register(room: Room) {
        room.add(delegate: self)
    }

    private func register(track: Track, in room: Room, localParticipant: LocalParticipant) {
        guard let sid = track.sid else { return }
        trackProperties[sid] = TrackProperties(identity: localParticipant.identity) { [weak room] in
            try await room?.send(dataPacket: $0)
        }
        track.add(delegate: self)
    }

    private func unregister(track: Track) {
        guard let sid = track.sid else { return }
        track.remove(delegate: self)
        trackProperties[sid] = nil
    }

    private func sendMetrics(track: Track, statistics: TrackStatistics) async {
        guard let sid = track.sid, let props = trackProperties[sid] else { return }
        let hash = statistics.hashValue
        guard hash != props.lastSentHash else { return }

        var dataPacket = Livekit_DataPacket()
        dataPacket.kind = .reliable
        dataPacket.metrics = Livekit_MetricsBatch(statistics: statistics, identity: props.identity)
        do {
            log("Sending track metrics...", .trace)
            try await props.transport(dataPacket)
            trackProperties[sid]?.lastSentHash = hash
        } catch {
            log("Failed to send metrics: \(error)", .warning)
        }
    }
}

// MARK: - Statistics -> protobufs

private extension Livekit_MetricsBatch {
    init(statistics: TrackStatistics, identity: Participant.Identity?) {
        var strings = OrderedSet<String>()
        defer { strData = strings.elements }

        addOutboundMetrics(from: statistics.outboundRtpStream, strings: &strings, identity: identity)
        addInboundMetrics(from: statistics.inboundRtpStream, strings: &strings, identity: identity)

        addRemoteOutboundMetrics(from: statistics.remoteOutboundRtpStream, strings: &strings, identity: identity)
        addRemoteInboundMetrics(from: statistics.remoteInboundRtpStream, strings: &strings, identity: identity)
    }

    mutating func addOutboundMetrics(from statistics: [OutboundRtpStreamStatistics], strings: inout OrderedSet<String>, identity: Participant.Identity?) {
        for stat in statistics where stat.kind == "video" {
            if let durations = stat.qualityLimitationDurations {
                addMetric(durations.cpu, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationCpu, strings: &strings, identity: identity, rid: stat.rid)
                addMetric(durations.bandwidth, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationBandwidth, strings: &strings, identity: identity, rid: stat.rid)
                addMetric(durations.other, at: stat.timestamp, label: .clientVideoPublisherQualityLimitationDurationOther, strings: &strings, identity: identity, rid: stat.rid)
            }
        }
    }

    mutating func addInboundMetrics(from statistics: [InboundRtpStreamStatistics], strings: inout OrderedSet<String>, identity: Participant.Identity?) {
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

    mutating func addRemoteOutboundMetrics(from statistics: [RemoteOutboundRtpStreamStatistics], strings: inout OrderedSet<String>, identity: Participant.Identity?) {
        for stat in statistics {
            addMetric(stat.roundTripTime, at: stat.timestamp, label: .publisherRtt, strings: &strings, identity: identity)
        }
    }

    mutating func addRemoteInboundMetrics(from statistics: [RemoteInboundRtpStreamStatistics], strings: inout OrderedSet<String>, identity: Participant.Identity?) {
        for stat in statistics {
            addMetric(stat.roundTripTime, at: stat.timestamp, label: .subscriberRtt, strings: &strings, identity: identity)
        }
    }

    mutating func addMetric(
        _ value: (some Numeric)?,
        at timestampUs: Double,
        label: Livekit_MetricLabel,
        strings: inout OrderedSet<String>,
        identity: Participant.Identity? = nil,
        sid: String? = nil,
        rid: String? = nil
    ) {
        guard let sample = createSample(timestampUs: timestampUs, value: value) else { return }
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

    func createSample(timestampUs: Double, value: (some Numeric)?) -> Livekit_MetricSample? {
        guard let floatValue = value?.floatValue else { return nil }
        guard floatValue != .zero else { return nil }

        var sample = Livekit_MetricSample()
        sample.timestampMs = Int64(timestampUs / 1000)
        sample.value = floatValue
        return sample
    }

    func createTimeSeries(
        label: Livekit_MetricLabel,
        strings: inout OrderedSet<String>,
        samples: [Livekit_MetricSample],
        identity: Participant.Identity? = nil,
        sid: String? = nil,
        rid: String? = nil
    ) -> Livekit_TimeSeriesMetric {
        var timeSeries = Livekit_TimeSeriesMetric()
        timeSeries.label = UInt32(label.rawValue)
        timeSeries.samples = samples

        if let identity {
            timeSeries.participantIdentity = getOrCreateIndex(in: &strings, inserting: identity.stringValue)
        }
        if let sid {
            timeSeries.trackSid = getOrCreateIndex(in: &strings, inserting: sid)
        }
        if let rid {
            timeSeries.rid = getOrCreateIndex(in: &strings, inserting: rid)
        }

        return timeSeries
    }

    /// Gets or creates an index for a custom string in the protobuf message
    /// starting from a predefined reserved value.
    ///
    /// Receivers should interpret index values as follows:
    /// ```
    /// if index < predefinedMaxValue {
    ///    MetricLabel(rawValue: index)
    /// } else {
    ///    str_data[index - 4096]
    /// }
    /// ```
    func getOrCreateIndex(in set: inout OrderedSet<String>, inserting string: String) -> UInt32 {
        let offset = Livekit_MetricLabel.predefinedMaxValue.rawValue
        let index = set.append(string).index
        return UInt32(index + offset)
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
