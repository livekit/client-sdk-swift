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
/// publishes or subscribes to and forwards each `getStats()` reading to the scope (the core
/// windows them into `lk.rtc.stats.sample`). It also owns the `lk.subscribe` span — subscription
/// intent to first media, "time to media" — because its natural end is an RTC fact: the first
/// reading with inbound bytes.
@Telemetry
final class RTCTelemetry: TelemetryInstrument, Loggable {
    /// A subscription that shows no media within this window ends with `error.type = timedOut`.
    nonisolated static let subscribeTimeout: TimeInterval = 30

    private nonisolated let scope: TelemetryScope
    private weak var room: Room?
    /// Open `lk.subscribe` spans by track, from subscription intent to first media.
    private var subscribeSpans: [Track.Sid: Span] = [:]
    private var subscribeTimeouts: [Track.Sid: Task<Void, Never>] = [:]

    nonisolated init(room: Room, scope: TelemetryScope) {
        self.scope = scope
        self.room = room
    }

    func start() {
        room?.add(delegate: self)
    }

    func stop() {
        room?.remove(delegate: self)
        for sid in subscribeSpans.keys {
            endSubscribe(sid, outcome: .cancelled)
        }
    }

    private func observe(_ track: Track) {
        track.add(delegate: self)
        // The core windows 1 Hz readings into 15 s samples; the timer is the SDK's existing one.
        Task { await track.set(reportStatistics: true) }
    }

    private func beginSubscribe(_ publication: RemoteTrackPublication, participant: RemoteParticipant, scope: TelemetryScope?) {
        let sid = publication.sid
        guard subscribeSpans[sid] == nil else { return }
        let span = Span.begin(.subscribe, in: scope, parent: nil)
        span.setTrack(publication.kind, source: publication.source, sid: sid, remoteIdentity: participant.identity?.stringValue)
        subscribeSpans[sid] = span
        subscribeTimeouts[sid]?.cancel()
        subscribeTimeouts[sid] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.subscribeTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.endSubscribe(sid, outcome: .error, error: LiveKitError(.timedOut, message: "No media within \(Self.subscribeTimeout)s"))
        }
    }

    private func endSubscribe(_ sid: Track.Sid, outcome: SpanOutcome, error: Error? = nil) {
        subscribeTimeouts.removeValue(forKey: sid)?.cancel()
        subscribeSpans.removeValue(forKey: sid)?.end(outcome: outcome, error: error.map(Span.errorType))
    }

    /// First media on a subscribed track: the subscribe span's natural end.
    private func mediaArrived(_ sid: Track.Sid) {
        guard let span = subscribeSpans[sid] else { return }
        span.step(.firstMedia)
        endSubscribe(sid, outcome: .ok)
    }
}

extension RTCTelemetry: RoomDelegate {
    nonisolated func room(_: Room, participant _: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        guard let track = publication.track else { return }
        Task { @Telemetry in self.observe(track) }
    }

    nonisolated func room(_: Room, participant _: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        publication.track?.remove(delegate: self)
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        // With autoSubscribe the intent exists the moment the track is known.
        guard room._state.connectOptions.autoSubscribe else { return }
        let scope = room.telemetryScope
        Task { @Telemetry in self.beginSubscribe(publication, participant: participant, scope: scope) }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        let scope = room.telemetryScope
        Task { @Telemetry in
            self.beginSubscribe(publication, participant: participant, scope: scope) // manual subscription
            self.subscribeSpans[publication.sid]?.step(.subscribed)
            if let track = publication.track { self.observe(track) }
        }
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        publication.track?.remove(delegate: self)
        Task { @Telemetry in self.endSubscribe(publication.sid, outcome: .cancelled) }
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        Task { @Telemetry in self.endSubscribe(publication.sid, outcome: .cancelled) }
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didFailToSubscribeTrackWithSid trackSid: Track.Sid, error: LiveKitError) {
        Task { @Telemetry in self.endSubscribe(trackSid, outcome: .error, error: error) }
    }
}

extension RTCTelemetry: TrackDelegate {
    nonisolated func track(_ track: Track, didUpdateStatistics statistics: TrackStatistics, simulcastStatistics _: [VideoCodec: TrackStatistics]) {
        for sample in Self.samples(for: track, statistics: statistics) {
            scope.recordStats(sample: sample)
        }
        // First media, at the stats timer's 1 s granularity.
        if let sid = track.sid, statistics.inboundRtpStream.contains(where: { ($0.bytesReceived ?? 0) > 0 }) {
            Task { @Telemetry in self.mediaArrived(sid) }
        }
    }

    /// One `RtcStatsSample` per RTP stream of the track; counters pass through as reported.
    nonisolated static func samples(for track: Track, statistics: TrackStatistics) -> [RtcStatsSample] {
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
        // One sample per RTP stream, tagged with its layer; the core folds simulcast layers into
        // the track (a suspended top layer must not freeze the counters).
        let rtt = statistics.remoteInboundRtpStream.first?.roundTripTime.map { $0 * 1000 }
        for stream in statistics.outboundRtpStream {
            var sample = RtcStatsSample(trackSid: sid, kind: kind, direction: .outbound)
            sample.layer = stream.id
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
