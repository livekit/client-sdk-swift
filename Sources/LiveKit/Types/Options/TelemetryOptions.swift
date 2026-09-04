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

import Foundation

/// Client telemetry: ships SDK diagnostics (warn/error records, per-track RTC statistics,
/// device state) out-of-band to an OTLP/HTTP collector. Process-wide: configure once with
/// ``LiveKitSDK/setTelemetry(_:)`` before creating Rooms.
@objcMembers
public final class TelemetryOptions: NSObject, Sendable {
    /// Full OTLP/HTTP logs URL, e.g. `http://localhost:4318/v1/logs` for a local collector.
    /// `nil` (the default) derives it from the server the first Room connects to
    /// (`https://<host>/observability/logs/otlp/v0`) and authenticates with the room token;
    /// until then everything is buffered on device.
    public let endpoint: URL?
    /// Extra request headers, e.g. `Authorization`.
    public let headers: [String: String]
    /// Directory for the on-disk batch cache; `nil` keeps batches in memory only.
    public let storageDirectory: URL?
    /// Export cadence in seconds. Stretched automatically under thermal / low-power pressure.
    public let flushInterval: TimeInterval
    /// RTC statistics window in seconds: one `lk.rtc.stats.sample` per track per window.
    public let statsWindow: TimeInterval
    /// Which instruments run; all by default. App-defined events and session identity are always on.
    public let instruments: TelemetryInstruments
    /// Lowest log level that leaves the device (design doc: warnings and errors). Events are not
    /// logs and are not subject to it; WebRTC's own logs go from `.error` regardless.
    public let logLevel: LogLevel

    /// `Caches/livekit-telemetry`: purgeable and excluded from backups — the right class for telemetry.
    public static var defaultStorageDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("livekit-telemetry", isDirectory: true)
    }

    public init(endpoint: URL? = nil,
                headers: [String: String] = [:],
                storageDirectory: URL? = TelemetryOptions.defaultStorageDirectory,
                flushInterval: TimeInterval = 15,
                statsWindow: TimeInterval = 15,
                instruments: TelemetryInstruments = .all,
                logLevel: LogLevel = .warning)
    {
        self.endpoint = endpoint
        self.headers = headers
        self.storageDirectory = storageDirectory
        self.flushInterval = flushInterval
        self.statsWindow = statsWindow
        self.instruments = instruments
        self.logLevel = logLevel
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return endpoint == other.endpoint &&
            headers == other.headers &&
            storageDirectory == other.storageDirectory &&
            flushInterval == other.flushInterval &&
            statsWindow == other.statsWindow &&
            instruments == other.instruments &&
            logLevel == other.logLevel
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(endpoint)
        hasher.combine(headers)
        hasher.combine(storageDirectory)
        hasher.combine(flushInterval)
        hasher.combine(statsWindow)
        hasher.combine(instruments.rawValue)
        hasher.combine(logLevel)
        return hasher.finalize()
    }
}

/// The telemetry instruments, by the design doc's areas. Combine to choose what runs.
public struct TelemetryInstruments: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Spans of the Room's operations: `lk.connect`, `lk.reconnect`, `lk.publish`.
    public static let room = TelemetryInstruments(rawValue: 1 << 0)
    /// Track statistics windows and the `lk.subscribe` span (time to media).
    public static let rtc = TelemetryInstruments(rawValue: 1 << 1)
    /// Warning and error log records from the SDK, the Rust core and WebRTC.
    public static let logs = TelemetryInstruments(rawValue: 1 << 2)
    /// Device state — thermal, power, memory, network, battery, lifecycle — and audio-session events.
    public static let device = TelemetryInstruments(rawValue: 1 << 3)

    public static let all: TelemetryInstruments = [.room, .rtc, .logs, .device]
}
