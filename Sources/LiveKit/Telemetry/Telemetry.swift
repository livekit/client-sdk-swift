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

/// Client telemetry: the one entry point.
///
/// `Telemetry.shared` owns the pipeline (the Rust core, `livekit-telemetry`), the process-level
/// instruments (device state, SDK logs) and one session per live Room. Configure it any time with
/// ``LiveKitSDK/setTelemetry(_:)``; it bootstraps when the first Room registers, and nothing but
/// trace ids and events crosses its boundary — sessions, handles and instruments stay inside.
/// As a global actor it is also the isolation domain for the instruments' Swift-side state; its
/// own entry points are synchronous and thread-safe (the core handles are).
@globalActor
public actor Telemetry {
    public static let shared = Telemetry()

    private struct Room_ {
        let session: TelemetrySession
        let rtc: RTCTelemetry
    }

    private struct State {
        var options: TelemetryOptions?
        var core: LiveKitUniFFI.Telemetry?
        /// Attributes set before the pipeline exists; applied at bootstrap.
        var attributes: [String: SpanAttribute?] = [:]
        var rooms: [ObjectIdentifier: Room_] = [:]
    }

    private nonisolated let state = StateSync(State())

    // MARK: - Configuration

    /// Set or change the options; `nil` turns telemetry off. Before the pipeline runs they shape it;
    /// afterwards the destination and headers apply at once and the cadence knobs on next launch.
    public nonisolated func configure(_ options: TelemetryOptions?) {
        let (core, previous) = state.mutate { state -> (LiveKitUniFFI.Telemetry?, LiveKitUniFFI.Telemetry?) in
            let previous = state.core
            state.options = options
            if options == nil { state.core = nil; state.rooms = [:] }
            return (options == nil ? nil : state.core, options == nil ? previous : nil)
        }
        if let previous {
            Task { @Telemetry in await Telemetry.stopInstruments(); await previous.shutdown() }
        }
        if let core, let options, let endpoint = options.endpoint {
            core.setDestination(endpoint: endpoint.absoluteString, headers: options.headers)
        }
    }

    /// Attach an attribute to every record of every session — an `enduser.id`, a tenant, a build
    /// flavor. `nil` removes it.
    public nonisolated func setAttribute(_ key: String, _ value: SpanAttribute?) {
        let core = state.mutate { state -> LiveKitUniFFI.Telemetry? in
            state.attributes[key] = value
            return state.core
        }
        core?.setAttribute(key: key, value: value?.lowered)
    }

    /// Cache everything queued and upload what the network allows.
    nonisolated func flush() {
        let core = state.copy().core
        Task { await core?.flush() }
    }

    /// Bounded final flush with the session summary; the pipeline stops.
    @Telemetry func shutdown() async {
        await Telemetry.stopInstruments()
        let core = state.mutate { state -> LiveKitUniFFI.Telemetry? in
            defer { state.core = nil; state.rooms = [:] }
            return state.core
        }
        await core?.shutdown()
    }

    // MARK: - Rooms

    /// A Room exists: bootstrap the pipeline if this is the first, give the Room a session (its
    /// own trace id) and start its instruments. A no-op when telemetry is off.
    nonisolated func register(_ room: Room) {
        let (core, rtc, bootstrapped) = state.mutate { state -> (LiveKitUniFFI.Telemetry?, RTCTelemetry?, Bool) in
            var bootstrapped = false
            if state.core == nil, let options = state.options, let core = Self.makeCore(options) {
                for (key, value) in state.attributes {
                    core.setAttribute(key: key, value: value?.lowered)
                }
                state.core = core
                bootstrapped = true
            }
            guard let core = state.core else { return (nil, nil, false) }
            let session = core.beginSession()
            let rtc = RTCTelemetry(room: room, session: session)
            state.rooms[ObjectIdentifier(room)] = Room_(session: session, rtc: rtc)
            return (core, rtc, bootstrapped)
        }
        guard let core, let rtc else { return }
        Task { @Telemetry in
            if bootstrapped { Telemetry.startInstruments(core) }
            rtc.start()
        }
    }

    /// The Room is going away: stop its instruments, ship what is queued. The session ends with it.
    nonisolated func unregister(_ room: Room) {
        guard let entry = state.mutate({ $0.rooms.removeValue(forKey: ObjectIdentifier(room)) }) else { return }
        let rtc = entry.rtc
        Task { @Telemetry in rtc.stop() }
        flush()
    }

    /// A connect attempt tells the pipeline where telemetry goes — the server's observability
    /// endpoint and the room token — unless the options named an endpoint. Everything cached until
    /// now starts uploading.
    nonisolated func connecting(to url: URL, token: String) {
        let state = state.copy()
        guard let core = state.core, state.options?.endpoint == nil,
              let endpoint = Self.observabilityEndpoint(for: url) else { return }
        core.setDestination(endpoint: endpoint, headers: ["Authorization": "Bearer \(token)"])
    }

    /// Session identity, attached to every record of the Room from now on.
    nonisolated func roomDidConnect(_ room: Room) {
        guard let session = session(for: room) else { return }
        for (key, value) in [("lk.room.sid", room.sid?.stringValue),
                             ("lk.room.name", room.name),
                             ("lk.participant.sid", room.localParticipant.sid?.stringValue),
                             ("lk.participant.identity", room.localParticipant.identity?.stringValue)]
        {
            session.setAttribute(key: key, value: value.map { .str($0) })
        }
    }

    /// The Room's session trace id (32 hex characters); `nil` when telemetry is off.
    nonisolated func traceId(for room: Room) -> String? {
        session(for: room)?.traceId()
    }

    /// An app-defined event in the Room's session; the core namespaces it under `custom.`.
    nonisolated func emit(_ name: String, attributes: [String: SpanAttribute], from room: Room) {
        session(for: room)?.emitCustom(name: name, attributes: attributes.lowered)
    }

    /// The span factory for a connection of this Room, bound to its session when telemetry is on.
    nonisolated func tracer(for room: Room) -> TelemetryTracer {
        session(for: room).map(TelemetryTracer.init(session:)) ?? .detached
    }

    private nonisolated func session(for room: Room) -> TelemetrySession? {
        state.copy().rooms[ObjectIdentifier(room)]?.session
    }

    // MARK: - Pipeline

    private nonisolated static func makeCore(_ options: TelemetryOptions) -> LiveKitUniFFI.Telemetry? {
        let config = TelemetryConfig(
            endpoint: options.endpoint?.absoluteString,
            headers: options.headers,
            resource: resource(),
            storageDir: options.storageDirectory?.path,
            flushIntervalMs: UInt64(max(0, options.flushInterval) * 1000),
            statsWindowMs: UInt64(max(0, options.statsWindow) * 1000),
        )
        // Fail-open: the app runs without telemetry rather than not at all.
        return try? LiveKitUniFFI.Telemetry(config: config, transport: URLSessionTelemetryTransport())
    }

    /// `wss://x.livekit.cloud/rtc` → `https://x.livekit.cloud/observability/logs/otlp/v0`.
    nonisolated static func observabilityEndpoint(for url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host != nil else { return nil }
        components.scheme = (components.scheme == "ws" || components.scheme == "http") ? "http" : "https"
        components.path = "/observability/logs/otlp/v0"
        components.query = nil
        return components.url?.absoluteString
    }

    // MARK: - Process-level instruments (isolated to this actor)

    @Telemetry private static var instruments: [TelemetryInstrument] = []

    @Telemetry private static func startInstruments(_ core: LiveKitUniFFI.Telemetry) {
        guard instruments.isEmpty else { return }
        instruments = [DeviceTelemetry(core: core), LoggingTelemetry(core: core)]
        for instrument in instruments {
            instrument.start()
        }
    }

    @Telemetry private static func stopInstruments() async {
        for instrument in instruments {
            instrument.stop()
        }
        instruments = []
    }

    // MARK: - Resource

    private static func resource() -> [LiveKitUniFFI.Attribute] {
        var attributes: [LiveKitUniFFI.Attribute] = [
            .init(key: "service.name", value: .str("livekit-client-swift")),
            .init(key: "service.version", value: .str(LiveKitSDK.version)),
            .init(key: "os.name", value: .str(String(describing: Utils.os()))),
            .init(key: "os.version", value: .str(Utils.osVersionString())),
        ]
        if let model = Utils.modelIdentifier() {
            attributes.append(.init(key: "device.model.identifier", value: .str(model)))
        }
        return attributes
    }
}

// MARK: - Attribute lowering

extension SpanAttribute {
    var lowered: LiveKitUniFFI.AttributeValue {
        switch self {
        case let .string(s): .str(s)
        case let .int(i): .int(i)
        case let .double(d): .double(d)
        case let .bool(b): .bool(b)
        }
    }
}

extension [String: SpanAttribute] {
    var lowered: [LiveKitUniFFI.Attribute] {
        map { .init(key: $0.key, value: $0.value.lowered) }
    }
}

// MARK: - Transport

/// The host's half of the pipeline: a dumb bytes mover. The core composed URL, headers and body;
/// this only performs the POST and maps the HTTP outcome onto `ExportError` so the core decides
/// retry / drop / go-silent.
final class URLSessionTelemetryTransport: TelemetryTransport, @unchecked Sendable {
    /// Background traffic class (`NET_SERVICE_TYPE_BK`): the local stack queues it below best-effort
    /// media and signaling (fq_codel BK class, Wi-Fi AC_BK) and switches its TCP flows to LEDBAT
    /// whenever foreground traffic is active — the one knob that actually protects the uplink.
    /// Ephemeral: no cookies, no cache; one connection.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.networkServiceType = .background
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    func send(request: ExportRequest) async throws {
        guard let url = URL(string: request.url) else {
            throw ExportError.Rejected(message: "invalid url \(request.url)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let response: URLResponse
        do {
            (_, response) = try await Self.session.data(for: urlRequest)
        } catch {
            throw ExportError.Retryable(message: error.localizedDescription, retryAfterMs: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ExportError.Retryable(message: "not an HTTP response", retryAfterMs: nil)
        }
        switch http.statusCode {
        case 200 ..< 300: return
        case 429, 502, 503, 504:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { UInt64($0) }.map { $0 * 1000 }
            throw ExportError.Retryable(message: "HTTP \(http.statusCode)", retryAfterMs: retryAfter)
        default:
            throw ExportError.Rejected(message: "HTTP \(http.statusCode)")
        }
    }
}
