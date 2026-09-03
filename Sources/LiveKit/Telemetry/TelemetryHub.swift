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

/// The process-wide telemetry pipeline (`livekit-telemetry`): one queue, cache and exporter for
/// every Room, started when the app configures telemetry (``LiveKitSDK/setTelemetry(_:)``) so
/// audio pre-initialization, permission failures and connect attempts that never reach a server
/// are captured. Infrastructure only: the core, the transport, the destination and the log relay
/// sink. The instruments are separate, independent components — ``DeviceTelemetry`` (started
/// here, process-level), ``RoomTelemetry`` and ``RTCTelemetry`` (one each per Room, on a session
/// from ``beginSession()``).
final class TelemetryHub: NSObject, @unchecked Sendable, Loggable {
    private static let _shared = StateSync<TelemetryHub?>(nil)
    static var shared: TelemetryHub? { _shared.copy() }

    /// Configure once, at launch; Rooms created afterwards get a session. `nil` turns telemetry
    /// off for new Rooms and shuts the previous pipeline down (bounded flush).
    static func configure(_ options: TelemetryOptions?) {
        let next = options.flatMap { TelemetryHub(options: $0) }
        let previous = _shared.mutate { current in
            defer { current = next }
            return current
        }
        previous?.shutdown()
    }

    let core: LiveKitUniFFI.Telemetry
    private let options: TelemetryOptions
    /// Process-level instruments (today: the device); Rooms own theirs.
    private let instruments: [TelemetryInstrument]

    /// `nil` only if the core refuses to start (no transport) — never the case here, but telemetry
    /// is fail-open: the app runs without it rather than not at all.
    private init?(options: TelemetryOptions) {
        let config = TelemetryConfig(
            endpoint: options.endpoint?.absoluteString,
            headers: options.headers,
            resource: Self.resource(),
            storageDir: options.storageDirectory?.path,
            flushIntervalMs: UInt64(max(0, options.flushInterval) * 1000),
            statsWindowMs: UInt64(max(0, options.statsWindow) * 1000),
        )
        guard let core = try? LiveKitUniFFI.Telemetry(config: config, transport: URLSessionTelemetryTransport()) else {
            return nil
        }
        self.core = core
        self.options = options
        let device = DeviceTelemetry(core: core)
        instruments = [device]
        super.init()

        LogRelay.shared.sinks.add(delegate: self)
        device.onTerminate = { [weak self] in self?.shutdown() }
        instruments.forEach { $0.start() }
    }

    /// A Room's session: its own trace id and attributes on this pipeline.
    func beginSession() -> TelemetrySession {
        core.beginSession()
    }

    /// A connect attempt tells the pipeline where telemetry goes — the server's observability
    /// endpoint and the room token — unless the options named an endpoint explicitly. Everything
    /// cached until now starts uploading.
    func connecting(to url: URL, token: String) {
        guard options.endpoint == nil, let endpoint = Self.observabilityEndpoint(for: url) else { return }
        core.setDestination(endpoint: endpoint, headers: ["Authorization": "Bearer \(token)"])
    }

    /// `wss://x.livekit.cloud/rtc` → `https://x.livekit.cloud/observability/logs/otlp/v0`.
    static func observabilityEndpoint(for url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host != nil else { return nil }
        components.scheme = (components.scheme == "ws" || components.scheme == "http") ? "http" : "https"
        components.path = "/observability/logs/otlp/v0"
        components.query = nil
        return components.url?.absoluteString
    }

    /// Cache everything queued and upload what the network allows.
    func flush() {
        let core = core
        Task { await core.flush() }
    }

    /// Bounded final flush (with the session summary); the pipeline stops afterwards.
    func shutdown() {
        instruments.forEach { $0.stop() }
        LogRelay.shared.sinks.remove(delegate: self)
        let core = core
        Task { await core.shutdown() }
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

// MARK: - Log records

extension TelemetryHub: LogRecordSink {
    func receive(_ record: LogRecord) {
        // Warn/error records point at the span the emitting task runs in (connect, reconnect,
        // publish). Logs from WebRTC threads have no ambient span and stay session-level.
        let ambient = Span.current
        let spanId = (ambient?.isEnded == false) ? ambient?.context?.spanId : nil
        core.emit(event: TelemetryEvent(
            name: "",
            severity: record.level == .error ? .error : .warn,
            body: record.message,
            attributes: [
                .init(key: "code.function", value: .str(record.function)),
                .init(key: "code.file.path", value: .str(record.file)),
                .init(key: "code.line.number", value: .int(Int64(record.line))),
                .init(key: "lk.log.type", value: .str(record.type)),
            ],
            spanId: spanId,
        ))
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
