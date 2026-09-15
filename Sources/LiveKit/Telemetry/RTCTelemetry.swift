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
internal import LiveKitWebRTC
import Foundation

/// The RTC-area instrument of one Room. It hands every track the Room publishes or subscribes to
/// the Room's telemetry scope — the track's own stats timer then forwards each raw `getStats()`
/// report, and the core maps and windows it — and reports the remote tracks' lifecycle so the
/// core can run the `lk.subscribe` span (intent → first media, ended by the first inbound reading
/// with bytes). No RTC state lives here.
actor RTCTelemetry {
    private nonisolated let scope: TelemetryScope
    private weak var room: Room?
    private var observed: [Track] = []

    init(room: Room, scope: TelemetryScope) {
        self.scope = scope
        self.room = room
    }

    func start() {
        room?.add(delegate: self)
    }

    func stop() {
        room?.remove(delegate: self)
        for track in observed {
            track._state.mutate { $0.telemetryScope = nil }
        }
        observed.removeAll()
    }

    private func observe(_ track: Track) {
        track._state.mutate { $0.telemetryScope = scope }
        observed.append(track)
        // The core windows 1 Hz readings into 15 s samples; the timer is the SDK's existing one.
        Task { await track.set(reportStatistics: true) }
    }

    private func forget(_ track: Track?) {
        guard let track else { return }
        track._state.mutate { $0.telemetryScope = nil }
        observed.removeAll { $0 === track }
    }

    private nonisolated func spanTrack(_ publication: RemoteTrackPublication, _ participant: RemoteParticipant) -> SpanTrack? {
        guard let kind = publication.kind.telemetry else { return nil }
        return SpanTrack(sid: publication.sid.stringValue, kind: kind, source: publication.source.telemetry,
                         remoteIdentity: participant.identity?.stringValue)
    }
}

extension RTCTelemetry: RoomDelegate {
    nonisolated func room(_: Room, participant _: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        guard let track = publication.track else { return }
        Task { await self.observe(track) }
    }

    nonisolated func room(_: Room, participant _: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        let track = publication.track
        Task { await self.forget(track) }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        // With autoSubscribe the intent exists the moment the track is known.
        guard room._state.connectOptions.autoSubscribe, let track = spanTrack(publication, participant) else { return }
        scope.subscribeStarted(track: track)
    }

    nonisolated func room(_: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        if let track = spanTrack(publication, participant) { scope.subscribed(track: track) }
        if let track = publication.track { Task { await self.observe(track) } }
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        scope.subscribeCancelled(sid: publication.sid.stringValue)
        let track = publication.track
        Task { await self.forget(track) }
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        scope.subscribeCancelled(sid: publication.sid.stringValue)
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didFailToSubscribeTrackWithSid trackSid: Track.Sid, error: LiveKitError) {
        scope.subscribeFailed(sid: trackSid.stringValue, errorType: Span.errorType(error))
    }
}

extension LKRTCStatisticsReport {
    /// The report as the core takes it: every entry with its standard members, nested maps
    /// flattened with a dot (`qualityLimitationDurations.cpu`). No field names known here.
    var telemetryStats: [RtcStat] {
        statistics.values.map { stat in
            var members: [String: AttributeValue] = [:]
            Self.flatten(stat.values, prefix: "", into: &members)
            return RtcStat(kind: stat.type, id: stat.id, members: members)
        }
    }

    var telemetryTimestampNs: UInt64 {
        UInt64(max(0, timestamp_us)) * 1000
    }

    private static func flatten(_ values: [String: NSObject], prefix: String, into members: inout [String: AttributeValue]) {
        for (key, value) in values {
            let name = prefix.isEmpty ? key : "\(prefix).\(key)"
            switch value {
            case let number as NSNumber:
                // A boxed Bool is an NSNumber too, and must stay one.
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    members[name] = .bool(number.boolValue)
                } else if number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 9e15 {
                    members[name] = .int(number.int64Value)
                } else {
                    members[name] = .double(number.doubleValue)
                }
            case let string as NSString:
                members[name] = .str(string as String)
            case let nested as [String: NSObject]:
                flatten(nested, prefix: name, into: &members)
            default:
                break // sequences carry nothing the core reads
            }
        }
    }
}
