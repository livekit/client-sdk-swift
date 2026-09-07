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

public import LiveKitUniFFI
import Foundation

/// Client telemetry. The pipeline lives in the core, one per process like a logger
/// (`telemetryConfigure`, `telemetryLog`, `telemetryScope` …), and so do the instruments it runs:
/// Swift only builds the platform ones and hands them over. Configure with
/// ``LiveKitSDK/setTelemetry(_:)`` before creating Rooms, like the logger.
public enum Telemetry {
    /// What was configured: the instruments a Room starts (`room`, `rtc`) and the log gate.
    static let options = StateSync<TelemetryConfig?>(nil)

    /// Where a log record came from.
    enum LogSource: String, Sendable {
        case sdk, ffi, webrtc
    }

    /// Set or change the options; `nil` turns telemetry off after a final flush. The pipeline
    /// starts now, so pre-connect errors are captured; its destination waits for the first connect
    /// unless the options name an endpoint.
    public static func configure(_ options: TelemetryConfig?) async {
        Self.options.mutate { $0 = options }
        LogHub.level.mutate { $0 = (options?.logSeverity ?? .warn).logLevel }
        guard var options else {
            await telemetryShutdown()
            return
        }
        // The platform's part of the config: who is reporting, and where the cache lives.
        options.sdk = TelemetryResource(sdk: .swift,
                                        sdkVersion: LiveKitSDK.version,
                                        osName: String(describing: Utils.os()),
                                        osVersion: Utils.osVersionString(),
                                        deviceModel: Utils.modelIdentifier())
        if options.storageDir == nil {
            options.storageDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("livekit-telemetry", isDirectory: true).path
        }
        var instruments: [TelemetryInstrument] = []
        if !options.disabledInstruments.contains(.device) { instruments.append(DeviceTelemetry()) }
        if !options.disabledInstruments.contains(.logs) { instruments.append(LogCapture(level: LogHub.level.copy())) }
        // Fail-open: the app runs without telemetry rather than not at all.
        try? telemetryConfigure(config: options, transport: URLSessionTelemetryTransport(), instruments: instruments)
    }

    /// Attach an attribute to every record of every scope — an `enduser.id`, a tenant, a build
    /// flavor. `nil` removes it.
    public static func setAttribute(_ key: String, _ value: AttributeValue?) {
        telemetrySetAttribute(key: key, value: value)
    }

    /// A one-line readout of the pipeline's health for a debug console: status, throughput,
    /// backlog and losses.
    public static func diagnostics() -> String {
        telemetryDiagnostics()
    }

    /// A warn/error record from the SDK, the Rust core or WebRTC, as `LogHub` captured it where it
    /// happened; the core files it under the ambient span's scope, or the process.
    static func log(_ record: LogRecord) {
        guard options.copy().map({ !$0.disabledInstruments.contains(.logs) }) == true else { return }
        let function = "\(record.function)", file = record.path.isEmpty ? "\(record.file)" : record.path
        telemetryLog(record: LiveKitUniFFI.LogRecord(severity: record.level.severity,
                                                     source: record.source.core,
                                                     message: record.message,
                                                     logger: record.category,
                                                     function: function.isEmpty ? nil : function,
                                                     file: file.isEmpty ? nil : file,
                                                     line: record.line > 0 ? UInt32(record.line) : nil,
                                                     timestampNs: record.timestampNs,
                                                     spanId: record.span?.spanId))
    }
}

/// Warn/error lines from the Rust core and from WebRTC, through the same `LogHub` the console
/// uses: each source is captured once, per process, from the configured floor up.
final class LogCapture: TelemetryInstrument, @unchecked Sendable {
    private let level: LogLevel

    init(level: LogLevel) {
        self.level = level
    }

    func start() {
        LogSources.ffi.enableTelemetry(level: level)
        LogSources.rtc.enableTelemetry(level: level)
    }

    func stop() {
        LogSources.ffi.disableTelemetry()
        LogSources.rtc.disableTelemetry()
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

extension Severity {
    var logLevel: LogLevel {
        switch self {
        case .trace, .debug: .debug
        case .info: .info
        case .warn: .warning
        case .error: .error
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
