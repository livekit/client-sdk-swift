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

/// The SDK-area instrument of one Room: its session identity (`lk.room.*`, `lk.participant.*`),
/// its spans (connect, reconnect, publish, subscribe) and its app-defined events, all filed under
/// the session the Room got from the ``TelemetryHub``. Created with the Room — so pre-connect
/// work is captured — and living as long as the Room does; connections come and go inside it.
/// Independent of ``RTCTelemetry`` (statistics) and ``DeviceTelemetry`` (the device), except for
/// one signal: first media on a subscribed track ends the `lk.subscribe` span.
final class RoomTelemetry: NSObject, TelemetryInstrument, @unchecked Sendable, Loggable {
    private let hub: TelemetryHub
    private let session: TelemetrySession
    private weak var room: Room?

    private struct State {
        /// Open `lk.subscribe` spans by track, from subscription intent to first media.
        var subscribeSpans: [Track.Sid: Span] = [:]
        var subscribeTimeouts: [Track.Sid: Task<Void, Never>] = [:]
    }

    /// A subscription that shows no media within this window ends with `error.type = timedOut`.
    static let subscribeTimeout: TimeInterval = 30

    private let _state = StateSync(State())

    init(room: Room, hub: TelemetryHub, session: TelemetrySession) {
        self.hub = hub
        self.session = session
        self.room = room
        super.init()
    }

    func start() {
        room?.add(delegate: self)
    }

    /// The Room is going away: settle open spans and ship what is queued.
    func stop() {
        room?.remove(delegate: self)
        connectionDidEnd()
    }

    /// The session's trace id: 32 hex characters, the handle support asks for.
    var traceId: String { session.traceId() }

    /// A connect attempt starts: the pipeline may learn its destination from the URL and token.
    func willConnect(url: URL, token: String) {
        hub.connecting(to: url, token: token)
    }

    /// Session identity, attached to every record from now on.
    func roomDidConnect(_ room: Room) {
        set("lk.room.sid", room.sid?.stringValue)
        set("lk.room.name", room.name)
        set("lk.participant.sid", room.localParticipant.sid?.stringValue)
        set("lk.participant.identity", room.localParticipant.identity?.stringValue)
    }

    /// The connection ended: settle open spans and ship what is queued. The session stays with
    /// the Room — a reconnect later is the same call.
    func connectionDidEnd() {
        for sid in _state.subscribeSpans.keys {
            endSubscribe(sid, outcome: .cancelled)
        }
        hub.flush()
    }

    /// First media on a subscribed track (from ``RTCTelemetry``): the subscribe span's natural end.
    func trackDidReceiveFirstMedia(_ sid: Track.Sid) {
        _state.subscribeSpans[sid]?.record("first_media")
        endSubscribe(sid, outcome: .ok)
    }

    /// A consumer-defined event; the core namespaces it under `custom.`.
    func emitCustom(_ name: String, attributes: [String: SpanAttribute]) {
        session.emitCustom(name: name, attributes: Self.lower(attributes))
    }

    private func set(_ key: String, _ value: String?) {
        session.setAttribute(key: key, value: value.map { .str($0) })
    }

    static func lower(_ attributes: [String: SpanAttribute]) -> [LiveKitUniFFI.Attribute] {
        attributes.map { key, value -> LiveKitUniFFI.Attribute in
            let lowered: LiveKitUniFFI.AttributeValue = switch value {
            case let .string(s): .str(s)
            case let .int(i): .int(i)
            case let .double(d): .double(d)
            case let .bool(b): .bool(b)
            }
            return .init(key: key, value: lowered)
        }
    }
}

// MARK: - Spans

extension RoomTelemetry: SpanSink {
    func spanDidBegin(_ span: Span) {
        let kind: LiveKitUniFFI.SpanKind = span.kind == .client ? .client : .internal
        let id = session.beginSpan(name: span.label, kind: kind, parent: span.parent?.context?.spanId)
        span.context = SpanContext(traceId: session.traceId(), spanId: id)
    }

    func span(_ span: Span, didRecord entry: Span.Entry) {
        guard let id = span.context?.spanId else { return }
        session.addSpanEvent(span: id, name: entry.label, attributes: [])
    }

    func spanDidEnd(_ span: Span) {
        guard let id = span.context?.spanId else { return }
        let outcome: LiveKitUniFFI.SpanOutcome = switch span.outcome ?? .ok {
        case .ok: .ok
        case .error: .error
        case .cancelled: .cancelled
        }
        session.endSpan(span: id, outcome: outcome, errorType: span.errorType, attributes: Self.lower(span.attributes))
    }
}

// MARK: - lk.subscribe — from the intent to subscribe to the first media that arrives

extension RoomTelemetry: RoomDelegate {
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        // With autoSubscribe the intent exists the moment the track is known.
        guard room._state.connectOptions.autoSubscribe else { return }
        beginSubscribe(publication, participant: participant)
    }

    nonisolated func room(_: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        if _state.subscribeSpans[publication.sid] == nil {
            beginSubscribe(publication, participant: participant) // manual subscription
        }
        _state.subscribeSpans[publication.sid]?.record("subscribed")
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        endSubscribe(publication.sid, outcome: .cancelled)
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        endSubscribe(publication.sid, outcome: .cancelled)
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didFailToSubscribeTrackWithSid trackSid: Track.Sid, error: LiveKitError) {
        endSubscribe(trackSid, outcome: .error, error: error)
    }

    private func beginSubscribe(_ publication: RemoteTrackPublication, participant: RemoteParticipant) {
        guard let tracer = room?.tracer else { return }
        let sid = publication.sid
        let span = tracer.beginSpan("lk.subscribe", parent: nil)
        span.setAttribute("lk.track.sid", .string(sid.stringValue))
        span.setAttribute("lk.track.kind", .string(Span.kindName(publication.kind)))
        span.setAttribute("lk.track.source", .string(String(describing: publication.source)))
        if let identity = participant.identity?.stringValue {
            span.setAttribute("lk.participant.remote_identity", .string(identity))
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.subscribeTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.endSubscribe(sid, outcome: .error, error: LiveKitError(.timedOut, message: "No media within \(Self.subscribeTimeout)s"))
        }
        _state.mutate {
            $0.subscribeSpans[sid] = span
            $0.subscribeTimeouts[sid]?.cancel()
            $0.subscribeTimeouts[sid] = timeout
        }
    }

    private func endSubscribe(_ sid: Track.Sid, outcome: SpanOutcome, error: Error? = nil) {
        let (span, timeout) = _state.mutate {
            ($0.subscribeSpans.removeValue(forKey: sid), $0.subscribeTimeouts.removeValue(forKey: sid))
        }
        timeout?.cancel()
        span?.end(outcome: outcome, error: error)
    }
}
