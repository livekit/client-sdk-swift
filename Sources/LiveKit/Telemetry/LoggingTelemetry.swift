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

/// The SDK-area log instrument: SDK log records, as data, into the pipeline — OpenTelemetry's
/// "log appender" bridge. It sits before the app's ``Logger`` (see ``LogRelay``), so
/// ``LiveKitSDK/setLogger(_:)`` cannot take it over and the console logging is untouched. The
/// relay hands over every level; this instrument decides what leaves the device.
@Telemetry
final class LoggingTelemetry: TelemetryInstrument {
    /// Design doc: only warn/error records leave the device; debug/info stay in the console.
    // ponytail: constant; a TelemetryOptions knob if info-level records are ever wanted remotely.
    nonisolated static let minLevel: LogLevel = .warning

    private nonisolated let core: LiveKitUniFFI.Telemetry

    nonisolated init(core: LiveKitUniFFI.Telemetry) {
        self.core = core
    }

    func start() {
        LogRelay.sink = self
    }

    func stop() {
        LogRelay.sink = nil
    }
}

extension LoggingTelemetry: LogSink {
    nonisolated func receive(_ record: LogRecord) {
        guard record.level >= Self.minLevel else { return }
        // Records point at the span the emitting task runs in (connect, reconnect, publish); the
        // core files them under that span's session. Records from WebRTC threads have no ambient
        // span and land in the process session.
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
