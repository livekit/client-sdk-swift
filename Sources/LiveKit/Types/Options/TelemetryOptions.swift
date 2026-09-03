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

    /// `Caches/livekit-telemetry`: purgeable and excluded from backups — the right class for telemetry.
    public static var defaultStorageDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("livekit-telemetry", isDirectory: true)
    }

    public init(endpoint: URL? = nil,
                headers: [String: String] = [:],
                storageDirectory: URL? = TelemetryOptions.defaultStorageDirectory,
                flushInterval: TimeInterval = 15,
                statsWindow: TimeInterval = 15)
    {
        self.endpoint = endpoint
        self.headers = headers
        self.storageDirectory = storageDirectory
        self.flushInterval = flushInterval
        self.statsWindow = statsWindow
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return endpoint == other.endpoint &&
            headers == other.headers &&
            storageDirectory == other.storageDirectory &&
            flushInterval == other.flushInterval &&
            statsWindow == other.statsWindow
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(endpoint)
        hasher.combine(headers)
        hasher.combine(storageDirectory)
        hasher.combine(flushInterval)
        hasher.combine(statsWindow)
        return hasher.finalize()
    }
}
