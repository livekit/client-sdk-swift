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

internal import LiveKitUniFFI
import Foundation

/// The RTC-area instrument of one Room: turns on `reportStatistics` for every track the Room
/// publishes or subscribes to, forwards each `getStats()` reading to the session (the core
/// windows them into `lk.rtc.stats.sample`), and reports when a subscribed track first carries
/// media. Independent of ``RoomTelemetry``; the Room wires ``onFirstMedia`` to it.
final class RTCTelemetry: NSObject, @unchecked Sendable, Loggable {
    private let session: TelemetrySession

    /// Called once per subscribed track, on the first reading with inbound bytes.
    var onFirstMedia: (@Sendable (Track.Sid) -> Void)?

    private struct State {
        /// Subscribed tracks that have not carried media yet.
        var awaitingMedia: Set<Track.Sid> = []
    }

    private let _state = StateSync(State())

    init(room: Room, session: TelemetrySession) {
        self.session = session
        super.init()
        room.add(delegate: self)
    }

    private func observe(_ track: Track) {
        track.add(delegate: self)
        // The core windows 1 Hz readings into 15 s samples; the timer is the SDK's existing one.
        Task { await track.set(reportStatistics: true) }
    }
}

extension RTCTelemetry: RoomDelegate {
    nonisolated func room(_: Room, participant _: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        if let track = publication.track { observe(track) }
    }

    nonisolated func room(_: Room, participant _: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        publication.track?.remove(delegate: self)
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        _state.mutate { $0.awaitingMedia.insert(publication.sid) }
        if let track = publication.track { observe(track) }
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        publication.track?.remove(delegate: self)
        _state.mutate { $0.awaitingMedia.remove(publication.sid) }
    }
}

extension RTCTelemetry: TrackDelegate {
    nonisolated func track(_ track: Track, didUpdateStatistics statistics: TrackStatistics, simulcastStatistics _: [VideoCodec: TrackStatistics]) {
        for sample in Self.samples(for: track, statistics: statistics) {
            session.recordStats(sample: sample)
        }
        // First media, at the stats timer's 1 s granularity.
        if let sid = track.sid, _state.awaitingMedia.contains(sid),
           statistics.inboundRtpStream.contains(where: { ($0.bytesReceived ?? 0) > 0 })
        {
            _state.mutate { $0.awaitingMedia.remove(sid) }
            onFirstMedia?(sid)
        }
    }

    /// One `RtcStatsSample` per RTP stream of the track; counters pass through as reported.
    static func samples(for track: Track, statistics: TrackStatistics) -> [RtcStatsSample] {
        guard let sid = track.sid?.stringValue else { return [] }
        let kind: TrackKind
        switch track.kind {
        case .audio: kind = .audio
        case .video: kind = .video
        case .none: return []
        }
        let codecs = Dictionary(statistics.codec.map { ($0.id, $0.mimeType) }, uniquingKeysWith: { first, _ in first })
        let ms: (Double?) -> UInt64? = { $0.map { UInt64(max(0, $0) * 1000) } }

        var samples: [RtcStatsSample] = []
        for stream in statistics.inboundRtpStream {
            var sample = RtcStatsSample(trackSid: sid, kind: kind, direction: .inbound)
            sample.codec = stream.codecId.flatMap { codecs[$0] ?? nil }
            sample.bytes = stream.bytesReceived
            sample.packets = stream.packetsReceived
            sample.packetsLost = stream.packetsLost.map { UInt64(max(0, $0)) }
            sample.freezeCount = stream.freezeCount.map(UInt64.init)
            sample.freezesDurationMs = ms(stream.totalFreezesDuration)
            sample.concealedSamples = stream.concealedSamples
            sample.concealmentEvents = stream.concealmentEvents
            sample.jitterBufferDelayMs = ms(stream.jitterBufferDelay)
            sample.jitterBufferEmittedCount = stream.jitterBufferEmittedCount
            sample.jitterMs = stream.jitter.map { $0 * 1000 }
            sample.framesPerSecond = stream.framesPerSecond
            sample.audioLevel = stream.audioLevel
            samples.append(sample)
        }
        let rtt = statistics.remoteInboundRtpStream.first?.roundTripTime.map { $0 * 1000 }
        for stream in statistics.outboundRtpStream {
            var sample = RtcStatsSample(trackSid: sid, kind: kind, direction: .outbound)
            sample.codec = stream.codecId.flatMap { codecs[$0] ?? nil }
            sample.bytes = stream.bytesSent
            sample.packets = stream.packetsSent
            sample.framesPerSecond = stream.framesPerSecond
            sample.rttMs = rtt
            sample.qualityLimitationBandwidthMs = ms(stream.qualityLimitationDurations?.bandwidth)
            sample.qualityLimitationCpuMs = ms(stream.qualityLimitationDurations?.cpu)
            samples.append(sample)
        }
        return samples
    }
}
