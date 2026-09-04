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
/// instruments (device state, log capture) and one session per live Room — all as actor state, so
/// there is no lock and no latch. Configure it any time with ``LiveKitSDK/setTelemetry(_:)``; the
/// pipeline bootstraps when the first Room asks for its session. Nothing but trace ids and events
/// crosses the boundary: sessions, handles and instruments stay inside. As a global actor it is
/// also the isolation domain for the instruments' state.
@globalActor
public actor Telemetry {
    public static let shared = Telemetry()

    private struct Entry {
        let session: TelemetrySession
        let rtc: RTCTelemetry?
    }

    /// Where a log record came from.
    enum LogSource: String, Sendable {
        case sdk, ffi, webrtc
    }

    private var options: TelemetryOptions?
    private var core: LiveKitUniFFI.Telemetry?
    /// Pipeline-wide attributes; kept so those set before bootstrap apply to it.
    private var attributes: [String: SpanAttribute?] = [:]
    private var rooms: [ObjectIdentifier: Entry] = [:]
    private var instruments: [TelemetryInstrument] = []

    // MARK: - Configuration

    /// Set or change the options; `nil` turns telemetry off. Before the pipeline runs they shape
    /// it; afterwards the destination and headers apply at once, the cadence knobs on next launch.
    public func configure(_ options: TelemetryOptions?) async {
        self.options = options
        LogHub.level.mutate { $0 = options?.logLevel ?? .warning }
        guard let options else {
            await stop()
            return
        }
        if let core, let endpoint = options.endpoint {
            core.setDestination(endpoint: endpoint.absoluteString, headers: options.headers)
        }
    }

    /// Attach an attribute to every record of every session — an `enduser.id`, a tenant, a build
    /// flavor. `nil` removes it.
    public func setAttribute(_ key: String, _ value: SpanAttribute?) {
        attributes[key] = value
        core?.setAttribute(key: key, value: value?.lowered)
    }

    /// A one-line readout of the pipeline's health, for a debug console: batches sent and cached,
    /// upload failures and timeouts, holds that hit their cap, records dropped by reason.
    public func diagnostics() async -> String {
        core?.diagnostics() ?? "telemetry: off"
    }

    /// Cache everything queued and upload what the network allows.
    func flush() async {
        await core?.flush()
    }

    /// Bounded final flush with the session summary; the pipeline stops.
    func shutdown() async {
        await stop()
    }

    private func stop() async {
        for instrument in instruments {
            await instrument.stop()
        }
        for entry in rooms.values {
            await entry.rtc?.stop()
        }
        instruments = []
        rooms = [:]
        let core = core
        self.core = nil
        await core?.shutdown()
    }

    // MARK: - Rooms

    /// A Room exists: give it a session now (and the pipeline, if this is the first).
    func register(_ room: Room) async {
        _ = await entry(for: room)
    }

    /// The Room is going away: stop its instruments, ship what is queued. The session ends with it.
    func unregister(_ room: ObjectIdentifier) async {
        guard let entry = rooms.removeValue(forKey: room) else { return }
        await entry.rtc?.stop()
        await core?.flush()
    }

    /// A connect attempt tells the pipeline where telemetry goes — the server's observability
    /// endpoint and the room token — unless the options named an endpoint. Everything cached until
    /// now starts uploading.
    func connecting(to url: URL, token: String) {
        core?.setServer(url: url.absoluteString, token: token)
    }

    /// Session identity, attached to every record of the Room from now on.
    func roomDidConnect(_ room: Room) async {
        guard let session = await entry(for: room)?.session else { return }
        session.setRoom(room: RoomIdentity(sid: room.sid?.stringValue,
                                           name: room.name,
                                           participantSid: room.localParticipant.sid?.stringValue,
                                           participantIdentity: room.localParticipant.identity?.stringValue))
    }

    /// The Room's session trace id (32 hex characters); `nil` when telemetry is off.
    func traceId(for room: Room) async -> String? {
        await entry(for: room)?.session.traceId()
    }

    /// An app-defined event in the Room's session; the core namespaces it under `custom.`.
    func emit(_ name: String, attributes: [String: SpanAttribute], from room: Room) async {
        await entry(for: room)?.session.emitCustom(name: name, attributes: attributes.lowered)
    }

    /// The Room's session for a connection's spans, when telemetry and the `room` instrument are on.
    func session(for room: Room) async -> TelemetrySession? {
        guard options?.instruments.contains(.room) == true else { return nil }
        return await entry(for: room)?.session
    }

    // MARK: - Logs

    /// A warn/error record from the SDK, the Rust core or WebRTC, as `LogHub` captured it where it
    /// happened; filed under the ambient span's session, or the process session.
    nonisolated static func log(_ record: LogRecord) {
        let function = "\(record.function)", file = record.path.isEmpty ? "\(record.file)" : record.path
        let typed = LiveKitUniFFI.LogRecord(severity: record.level.severity,
                                            source: record.source.core,
                                            message: record.message,
                                            logger: record.category,
                                            function: function.isEmpty ? nil : function,
                                            file: file.isEmpty ? nil : file,
                                            line: record.line > 0 ? UInt32(record.line) : nil,
                                            timestampNs: record.timestampNs,
                                            spanId: record.span?.spanId)
        Task { await shared.receive(typed) }
    }

    private func receive(_ record: LiveKitUniFFI.LogRecord) {
        guard options?.instruments.contains(.logs) == true else { return }
        core?.log(record: record)
    }

    /// The Room's session, created on first use — together with the pipeline and its process-level
    /// instruments when this is the first Room. `nil` while telemetry is off. State is updated
    /// before every `await`, so a concurrent call for the same Room finds the entry.
    private func entry(for room: Room) async -> Entry? {
        let id = ObjectIdentifier(room)
        if let existing = rooms[id] { return existing }
        if core == nil {
            guard let options, let made = Self.makeCore(options) else { return nil }
            for (key, value) in attributes {
                made.setAttribute(key: key, value: value?.lowered)
            }
            core = made
            if options.instruments.contains(.device) {
                instruments = [DeviceTelemetry(core: made)]
            }
            for instrument in instruments {
                await instrument.start()
            }
            if options.instruments.contains(.logs) {
                startLogCapture()
            }
        }
        guard let core, let options else { return nil }
        let session = core.beginSession()
        let entry = Entry(session: session,
                          rtc: options.instruments.contains(.rtc) ? RTCTelemetry(room: room, session: session) : nil)
        rooms[id] = entry
        await entry.rtc?.start()
        return entry
    }

    /// Warn/error logs from the Rust core and from WebRTC, through the same `LogHub` the console
    /// uses (see `LogSources`): each source is captured once, per process.
    private func startLogCapture() {
        // Capture at the configured floor; the core applies the per-source policy.
        LogSources.ffi.enableTelemetry(level: LogHub.level.copy())
        LogSources.rtc.enableTelemetry(level: LogHub.level.copy())
    }

    // MARK: - Pipeline

    private static func makeCore(_ options: TelemetryOptions) -> LiveKitUniFFI.Telemetry? {
        let config = TelemetryConfig(
            endpoint: options.endpoint?.absoluteString,
            headers: options.headers,
            resource: [],
            sdk: TelemetryResource(sdk: .swift,
                                   sdkVersion: LiveKitSDK.version,
                                   osName: String(describing: Utils.os()),
                                   osVersion: Utils.osVersionString(),
                                   deviceModel: Utils.modelIdentifier()),
            storageDir: options.storageDirectory?.path,
            flushIntervalMs: UInt64(max(0, options.flushInterval) * 1000),
            statsWindowMs: UInt64(max(0, options.statsWindow) * 1000),
            logSeverity: options.logLevel == .error ? .error : options.logLevel == .warning ? .warn : options.logLevel == .info ? .info : .debug,
        )
        // Fail-open: the app runs without telemetry rather than not at all.
        return try? LiveKitUniFFI.Telemetry(config: config, transport: URLSessionTelemetryTransport())
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

extension Telemetry.LogSource {
    var core: LiveKitUniFFI.LogSource {
        switch self {
        case .sdk: .sdk
        case .ffi: .ffi
        case .webrtc: .webRtc
        }
    }
}

extension LogLevel {
    var severity: Severity {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .warn
        case .error: .error
        }
    }
}

extension Track.Kind {
    var telemetry: TrackKind? {
        switch self {
        case .audio: .audio
        case .video: .video
        case .none: nil
        }
    }
}
