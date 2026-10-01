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

/// A Room's RTC instrument. Reports the tracks' lifecycle, from which the core runs the
/// `lk.subscribe` span (intent → first media), and hands it one raw `getStats()` report per peer
/// connection as often as it asks; the core maps every RTP stream to its track and windows it.
/// Owned by the Room, registered as its (weakly held) delegate.
final class RTCTelemetry: NSObject, Sendable {
    private struct Polling {
        var loop: AnyTaskCancellable?
        /// When the running loop reads next (`DispatchTime` uptime nanoseconds).
        var next: UInt64 = .max
    }

    private let scope: TelemetryScope
    private let polling = StateSync(Polling())

    init(room: Room, scope: TelemetryScope) {
        self.scope = scope
        super.init()
        room.delegates.add(internalDelegate: self) // out of reach of the app's removeAllDelegates()
        Telemetry.rtcInstruments.mutate { $0.add(self) }
        poll(room)
    }

    /// Whether a polling loop is running.
    var isPolling: Bool { polling.read { $0.loop != nil } }

    /// The opt-out: no reading from now on. Never blocks: cancelling only flags the loop.
    func stop() {
        polling.mutate { $0 = Polling(loop: nil, next: 0) }
    }

    /// At join and after a full reconnect (whose join announces no participants yet), under
    /// autoSubscribe: the tracks announced and not yet subscribed are wanted from now on.
    func joined(_ room: Room) {
        guard room._state.connectOptions.autoSubscribe else { return }
        for participant in room.remoteParticipants.values {
            for case let publication as RemoteTrackPublication in participant.trackPublications.values where publication.track == nil {
                guard let track = SpanTrack(publication, remoteIdentity: participant.identity?.stringValue) else { continue }
                scope.subscribeStarted(track: track)
            }
        }
        poll(room)
    }

    /// Intent to subscribe: the core polls faster until first media, so start a fresh wait.
    func subscribeStarted(_ publication: RemoteTrackPublication, of participant: RemoteParticipant, in room: Room) {
        guard let track = SpanTrack(publication, remoteIdentity: participant.identity?.stringValue) else { return }
        scope.subscribeStarted(track: track)
        poll(room)
    }

    /// Makes the next reading come no later than the core's current interval from now: a wait
    /// it just shortened (a subscribe awaiting first media, a track awaiting its first outbound
    /// reading) starts now, a sooner reading already due is kept. The loop lives as long as the
    /// Room and this instrument; while disconnected it wakes at the idle interval (30 s by
    /// default) and reads nothing, which costs less than tracking the connection state here.
    func poll(_ room: Room) {
        let wait = scope.statsPollIntervalMs() * 1_000_000
        let next = DispatchTime.now().uptimeNanoseconds + wait
        polling.mutate { polling in
            guard next < polling.next, !Telemetry.disabled.copy() else { return }
            polling.next = next
            polling.loop = loop(room, firstWait: wait)
        }
    }

    private func loop(_ room: Room, firstWait: UInt64) -> AnyTaskCancellable {
        let scope = scope
        return Task { [weak self, weak room] in
            var wait = firstWait
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: wait)
                guard !Task.isCancelled, !Telemetry.disabled.copy(), let room else { return }
                await room.recordPeerStats(into: scope)
                wait = scope.statsPollIntervalMs() * 1_000_000
                let next = DispatchTime.now().uptimeNanoseconds + wait
                self?.polling.mutate { if !Task.isCancelled { $0.next = next } }
            }
        }.cancellable()
    }
}

extension RTCTelemetry: RoomDelegate {
    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        // With autoSubscribe the intent exists the moment the track is known.
        guard room._state.connectOptions.autoSubscribe else { return }
        subscribeStarted(publication, of: participant, in: room)
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let track = SpanTrack(publication, remoteIdentity: participant.identity?.stringValue) else { return }
        scope.subscribed(track: track)
        poll(room) // the core may poll faster now (a subscribe it had not seen opens here)
    }

    func room(_: Room, participant _: RemoteParticipant, didFailToSubscribeTrackWithSid trackSid: Track.Sid, error: LiveKitError) {
        scope.subscribeFailed(sid: trackSid.stringValue, errorType: TelemetrySpan.errorType(error))
    }

    func room(_: Room, participant _: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        scope.trackEnded(sid: publication.sid.stringValue)
    }

    func room(_: Room, participant _: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        scope.trackEnded(sid: publication.sid.stringValue)
    }

    func room(_: Room, participant _: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        scope.trackEnded(sid: publication.sid.stringValue)
    }
}

// MARK: - Stats

extension Room {
    /// One `getStats()` report per peer connection, with every track this Room sends or receives.
    /// Each request and each submission is admitted under the opt-out lock, so none starts once
    /// ``LiveKitSDK/disableTelemetry()`` has returned; a report already requested is dropped, and
    /// so is a connection that does not answer within 5 s. Returns the reports answered and submitted.
    @discardableResult
    func recordPeerStats(into scope: TelemetryScope) async -> (answered: Int, submitted: Int) {
        guard let transports = _state.transport?.allTransports else { return (0, 0) }
        var tracks: [String: String] = [:]
        for participant in [localParticipant as Participant] + remoteParticipants.values.map(\.self) {
            for publication in participant.trackPublications.values {
                if let track = publication.track { tracks[track.mediaTrack.trackId] = publication.sid.stringValue }
            }
        }
        var counts = (answered: 0, submitted: 0)
        for transport in transports {
            guard let report = await transport.telemetryStatistics() else { continue } // opted out, or no answer
            counts.answered += 1
            let stats = report.telemetryStats // flattened outside the lock
            await Telemetry.beforeGate?(.submit)
            guard Telemetry.ifCollecting({
                scope.recordPeerStats(report: stats, tracks: tracks, timestampNs: report.telemetryTimestampNs)
            }) else { break }
            counts.submitted += 1
        }
        return counts
    }
}

extension LKRTCStatisticsReport {
    /// Every entry with its standard members as the core takes them, nested maps flattened with a
    /// dot (`qualityLimitationDurations.cpu`). No member names are known here.
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
