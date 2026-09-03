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

/// The telemetry subsystem — pipeline, configuration and instruments — as a global actor.
///
/// Configure once, before any Room exists, like the logger: ``LiveKitSDK/setTelemetry(_:)`` or
/// ``LiveKitSDK/disableTelemetry()``. The pipeline (the Rust core, `livekit-telemetry`) is built
/// from those options on first use and latched for the process; every Room then gets a session
/// with its own trace id. Swift-side telemetry state — instrument state, lifecycle — is isolated to
/// this actor; the core handles are thread-safe and used directly from wherever the SDK runs.
@globalActor
public actor Telemetry {
    public static let shared = Telemetry()

    // MARK: - Configuration (static, before use)

    private struct Config {
        var options: TelemetryOptions?
    }

    private static let config = StateSync(Config())

    /// Store the options; the pipeline starts on first use and is latched then, like `sharedLogger`.
    nonisolated static func configure(_ options: TelemetryOptions?) {
        config.mutate { $0.options = options }
    }

    /// The pipeline and the options it was built from; `nil` when telemetry is off. Built once.
    private nonisolated static let latched: (options: TelemetryOptions, core: LiveKitUniFFI.Telemetry)? = {
        guard let options = config.copy().options else { return nil }
        let coreConfig = TelemetryConfig(
            endpoint: options.endpoint?.absoluteString,
            headers: options.headers,
            resource: resource(),
            storageDir: options.storageDirectory?.path,
            flushIntervalMs: UInt64(max(0, options.flushInterval) * 1000),
            statsWindowMs: UInt64(max(0, options.statsWindow) * 1000),
        )
        // Fail-open: the app runs without telemetry rather than not at all.
        guard let core = try? LiveKitUniFFI.Telemetry(config: coreConfig, transport: URLSessionTelemetryTransport()) else { return nil }
        return (options, core)
    }()

    /// The core pipeline, or `nil` when telemetry is off.
    nonisolated static var core: LiveKitUniFFI.Telemetry? { latched?.core }

    // MARK: - Pipeline-wide

    /// Attach an attribute to every record of every session — an `enduser.id`, a tenant, a build
    /// flavor. `nil` removes it. Room identity is set per session by the SDK.
    public nonisolated static func setAttribute(_ key: String, _ value: SpanAttribute?) {
        core?.setAttribute(key: key, value: value?.lowered)
    }

    /// A connect attempt tells the pipeline where telemetry goes — the server's observability
    /// endpoint and the room token — unless the options named an endpoint. Everything cached until
    /// now starts uploading.
    nonisolated static func connecting(to url: URL, token: String) {
        guard let latched, latched.options.endpoint == nil, let endpoint = observabilityEndpoint(for: url) else { return }
        latched.core.setDestination(endpoint: endpoint, headers: ["Authorization": "Bearer \(token)"])
    }

    /// `wss://x.livekit.cloud/rtc` → `https://x.livekit.cloud/observability/logs/otlp/v0`.
    nonisolated static func observabilityEndpoint(for url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host != nil else { return nil }
        components.scheme = (components.scheme == "ws" || components.scheme == "http") ? "http" : "https"
        components.path = "/observability/logs/otlp/v0"
        components.query = nil
        return components.url?.absoluteString
    }

    /// Cache everything queued and upload what the network allows.
    nonisolated static func flush() {
        let core = core
        Task { await core?.flush() }
    }

    // MARK: - Instruments (isolated to this actor)

    @Telemetry private static var instruments: [TelemetryInstrument] = []

    /// Start the process-level instruments (device, logs) once the pipeline exists. Idempotent.
    @Telemetry static func start() {
        guard instruments.isEmpty, let core else { return }
        instruments = [DeviceTelemetry(core: core), LoggingTelemetry(core: core)]
        for instrument in instruments {
            instrument.start()
        }
    }

    /// Stop the instruments and flush a last time, with the session summary; the pipeline stops.
    @Telemetry static func shutdown() async {
        for instrument in instruments {
            instrument.stop()
        }
        instruments = []
        await core?.shutdown()
    }

    // MARK: - Resource

    private nonisolated static func resource() -> [LiveKitUniFFI.Attribute] {
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
