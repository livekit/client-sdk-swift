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
import OSLog

// MARK: - Logger

public typealias ScopedMetadata = CustomStringConvertible
public typealias ScopedMetadataContainer = [String: ScopedMetadata]

public protocol Logger: Sendable {
    // swiftlint:disable:next function_parameter_count
    func log(
        _ message: @autoclosure () -> CustomStringConvertible,
        _ level: LogLevel,
        source: @autoclosure () -> String?,
        file: StaticString,
        type: Any.Type,
        function: StaticString,
        line: UInt,
        metaData: ScopedMetadataContainer,
    )
}

// Default arguments
public extension Logger {
    func log(
        _ message: @autoclosure () -> CustomStringConvertible,
        _ level: LogLevel = .debug,
        source: @autoclosure () -> String? = nil,
        file: StaticString = #fileID,
        type: Any.Type,
        function: StaticString = #function,
        line: UInt = #line,
        metaData: ScopedMetadataContainer = ScopedMetadataContainer(),
    ) {
        log(message(), level, source: source(), file: file, type: type, function: function, line: line, metaData: metaData)
    }
}

/// A no-op logger
public struct DisabledLogger: Logger {
    @inlinable
    // swiftlint:disable:next function_parameter_count
    public func log(
        _: @autoclosure () -> CustomStringConvertible,
        _: LogLevel,
        source _: @autoclosure () -> String?,
        file _: StaticString,
        type _: Any.Type,
        function _: StaticString,
        line _: UInt,
        metaData _: ScopedMetadataContainer,
    ) {}
}

/// A simple `print` logger suitable for debugging in terminal environments outside Xcode
public struct PrintLogger: Logger {
    private let minLevel: LogLevel
    private let colors: Bool

    public init(minLevel: LogLevel = .info, colors: Bool = true) {
        self.minLevel = minLevel
        self.colors = colors
    }

    // swiftlint:disable:next function_parameter_count
    public func log(
        _ message: @autoclosure () -> CustomStringConvertible,
        _ level: LogLevel,
        source _: @autoclosure () -> String?,
        file _: StaticString,
        type: Any.Type,
        function: StaticString,
        line _: UInt,
        metaData _: ScopedMetadataContainer,
    ) {
        guard level >= minLevel else { return }
        print("[\(colorCode(level))\(level)\(resetCode)] \(type).\(function) \(message())")
    }

    private func colorCode(_ level: LogLevel) -> String {
        guard colors else { return "" }
        switch level {
        case .debug: return "\u{001B}[36m"
        case .info: return "\u{001B}[94m"
        case .warning: return "\u{001B}[33m"
        case .error: return "\u{001B}[31m"
        }
    }

    private var resetCode: String {
        colors ? "\u{001B}[0m" : ""
    }
}

/// A logger that logs to OSLog
/// - Parameter minLevel: The minimum level to log
/// - Parameter rtc: Whether to log WebRTC output
/// - Parameter ffi: Whether to log Rust FFI output
open class OSLogger: Logger, @unchecked Sendable {
    private static let subsystem = "io.livekit.sdk"

    private let queue = DispatchQueue(label: "io.livekit.oslogger", qos: .utility)
    private var logs: [String: OSLog] = [:]

    private let minLevel: LogLevel

    public init(minLevel: LogLevel = .info, rtc: Bool = false, ffi: Bool = true) {
        self.minLevel = minLevel

        // External sources arrive through `log(...)` like any other record, typed `WebRTCLog` / `FFILog`.
        if rtc { LogSources.rtc.enable(console: minLevel) }
        if ffi { LogSources.ffi.enable(console: minLevel) }
    }

    // swiftlint:disable:next function_parameter_count
    public func log(
        _ message: @autoclosure () -> CustomStringConvertible,
        _ level: LogLevel,
        source _: @autoclosure () -> String?,
        file _: StaticString,
        type: Any.Type,
        function: StaticString,
        line _: UInt,
        metaData: ScopedMetadataContainer,
    ) {
        guard level >= minLevel else { return }

        let message = message().description

        func buildScopedMetadataString() -> String {
            guard !metaData.isEmpty else { return "" }
            return " [\(metaData.map { "\($0): \($1)" }.joined(separator: ", "))]"
        }

        let metadata = buildScopedMetadataString()

        queue.async {
            func getOSLog(for type: Any.Type) -> OSLog {
                let typeName = String(describing: type)

                if let cachedLog = self.logs[typeName] {
                    return cachedLog
                }

                let newLog = OSLog(subsystem: Self.subsystem, category: typeName)
                self.logs[typeName] = newLog
                return newLog
            }

            let scope = "\(function)".isEmpty ? "\(type)" : "\(type).\(function)"
            os_log("%{public}@", log: getOSLog(for: type), type: level.osLogType, "\(scope) \(message)\(metadata)")
        }
    }
}

// MARK: - Loggable

/// Allows to extend with custom `log` method which automatically captures current type (class name).
public protocol Loggable {}

extension Loggable {
    func log(_ message: CustomStringConvertible? = nil,
             _ level: LogLevel = .debug,
             file: StaticString = #fileID,
             function: StaticString = #function,
             line: UInt = #line)
    {
        Self.log(message ?? "",
                 level,
                 file: file,
                 function: function,
                 line: line)
    }

    static func log(_ message: CustomStringConvertible? = nil,
                    _ level: LogLevel = .debug,
                    file: StaticString = #fileID,
                    function: StaticString = #function,
                    line: UInt = #line)
    {
        LogHub.emit(LogRecord(level: level, source: .sdk, type: Self.self, function: function, file: file, line: line,
                              message: message?.description ?? ""))
    }
}

// MARK: - Log hub

/// Records that did not originate in Swift carry these as their `type`, so loggers can tell.
enum FFILog {}
enum WebRTCLog {}

/// One log line as a value — the record every destination receives (swift-otel's `OTelLogRecord`
/// shape). Captured where the log happened: level, origin, code location, the message, and the
/// ambient span so console and telemetry correlate.
struct LogRecord: Sendable {
    let level: LogLevel
    let source: Telemetry.LogSource
    /// The Swift type that logged, or a marker (`FFILog`, `WebRTCLog`) for external sources.
    let type: Any.Type
    /// Rust target / WebRTC / the Swift type name — what telemetry files under `lk.log.type`.
    let category: String
    let function: StaticString
    let file: StaticString
    let line: UInt
    /// Source path for external records (the Rust file); `file` is the SDK's `#fileID`.
    let path: String
    let message: String
    let timestampNs: UInt64
    /// The span the emitting task runs in, if any and still open.
    let span: SpanContext?

    init(level: LogLevel, source: Telemetry.LogSource, type: Any.Type, category: String? = nil,
         function: StaticString = "", file: StaticString = "", line: UInt = 0, path: String = "", message: String)
    {
        self.level = level
        self.source = source
        self.type = type
        self.category = category ?? String(describing: type)
        self.function = function
        self.file = file
        self.line = line
        self.path = path
        self.message = message
        timestampNs = UInt64(Date().timeIntervalSince1970 * 1e9)
        let ambient = Span.current
        span = (ambient?.isEnded == false) ? ambient?.context : nil
    }
}

/// Every log line the SDK produces or captures — its own `Loggable.log` calls, the Rust core's,
/// WebRTC's — passes through here once and goes two ways: to the app's ``Logger``, which filters
/// by its own level, and, at warn/error, to telemetry, whose threshold is fixed. Neither side
/// learns the other's level (swift-log's `MultiplexLogHandler`, Datadog's console format vs
/// `remoteLogThreshold`). The ambient span travels with the record to both, the way swift-log's
/// `MetadataProvider` attaches trace context: console lines and telemetry records correlate.
/// External sources are captured only while someone asked (``LogSources``), and the console sees
/// them from the level it asked for.
enum LogHub {
    /// The configured threshold (`TelemetryOptions.logLevel`, default warning), set by `Telemetry`.
    static let level = StateSync<LogLevel>(.warning)

    /// What leaves the device: the configured level for the SDK and the Rust core; errors only from
    /// WebRTC, whose "warnings" are internal chatter (duplicate codecs, disabled field trials, RTCP
    /// timeouts — 60 of 77 records in one call) that would eat the flood budget and say nothing the
    /// stats don't.
    static func telemetryLevel(for source: Telemetry.LogSource) -> LogLevel {
        source == .webrtc ? max(level.copy(), .error) : level.copy()
    }

    static func emit(_ record: LogRecord) {
        // The core's own warnings ("cannot cache", "batch rejected") stay out of telemetry: a rejected
        // batch that produced a record that produced a batch would never end.
        if record.level >= telemetryLevel(for: record.source),
           !(record.source == .ffi && record.category.hasPrefix("livekit_telemetry"))
        {
            Telemetry.log(record)
        }
        if record.source == .sdk || LogSources.consoleLevel(record.source).map({ record.level >= $0 }) == true {
            var metaData = ScopedMetadataContainer()
            if let span = record.span {
                metaData["lk.trace_id"] = span.traceId
                metaData["lk.span_id"] = String(span.spanId, radix: 16)
            }
            sharedLogger.log(record.message, record.level, file: record.file, type: record.type,
                             function: record.function, line: record.line, metaData: metaData)
        }
    }
}

/// An external log source — the Rust core, WebRTC — with one subscription per process. Runs at the
/// lowest level any consumer asked for; ``LogHub`` filters per consumer.
final class LogSource: @unchecked Sendable {
    private struct State {
        var console: LogLevel?
        var telemetry: LogLevel?
        var running: LogLevel?
    }

    private let state = StateSync(State())
    private let begin: @Sendable (LogLevel) -> Void
    private let adjust: @Sendable (LogLevel) -> Void

    init(begin: @escaping @Sendable (LogLevel) -> Void, adjust: @escaping @Sendable (LogLevel) -> Void) {
        self.begin = begin
        self.adjust = adjust
    }

    /// The level the console asked for; `nil` means the console gets nothing from this source.
    var consoleLevel: LogLevel? { state.copy().console }

    /// The console (the app's logger) wants this source from `level` up.
    func enable(console level: LogLevel) {
        request { $0.console = min($0.console ?? level, level) }
    }

    /// Telemetry wants this source from `level` up (see `LogHub.telemetryLevel(for:)`).
    func enableTelemetry(level: LogLevel) {
        request { $0.telemetry = level }
    }

    private func request(_ change: (inout State) -> Void) {
        let (was, now) = state.mutate { state -> (LogLevel?, LogLevel?) in
            change(&state)
            let wanted = [state.console, state.telemetry].compactMap(\.self).min()
            let was = state.running
            if let wanted, was.map({ wanted < $0 }) ?? true { state.running = wanted }
            return (was, state.running)
        }
        guard let now, now != was else { return }
        was == nil ? begin(now) : adjust(now)
    }
}

enum LogSources {
    /// The Rust core: `logForwardReceive` has one consumer.
    static let ffi = LogSource(
        begin: { level in
            logForwardBootstrap(level: level.logForwardFilter)
            Task(priority: .utility) {
                while let entry = await logForwardReceive() {
                    LogHub.emit(LogRecord(level: LogLevel(entry.level), source: .ffi, type: FFILog.self, category: entry.target,
                                          line: entry.line.map { UInt($0) } ?? 0, path: entry.file ?? "",
                                          message: "\(entry.target) \(entry.message)"))
                }
            }
        },
        adjust: { logForwardBootstrap(level: $0.logForwardFilter) },
    )

    /// WebRTC: one callback logger for the process.
    static let rtc: LogSource = {
        let logger = LKRTCCallbackLogger()
        return LogSource(
            begin: { level in
                logger.severity = level.rtcSeverity
                logger.start { message, severity in
                    LogHub.emit(LogRecord(level: LogLevel(severity), source: .webrtc, type: WebRTCLog.self, category: "WebRTC",
                                          message: message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            },
            adjust: { logger.severity = $0.rtcSeverity },
        )
    }()

    static func consoleLevel(_ source: Telemetry.LogSource) -> LogLevel? {
        switch source {
        case .ffi: ffi.consoleLevel
        case .webrtc: rtc.consoleLevel
        case .sdk: .debug
        }
    }
}

// MARK: - Level

@objc
@frozen
public enum LogLevel: Int, Sendable, Comparable, CustomStringConvertible {
    case debug
    case info
    case warning
    case error

    @inlinable
    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        }
    }

    var rtcSeverity: LKRTCLoggingSeverity {
        switch self {
        case .debug: .verbose
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
    }

    var logForwardFilter: LogForwardFilter {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .warn
        case .error: .error
        }
    }

    @inlinable
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}

extension LogLevel {
    init(_ level: LogForwardLevel) {
        self = switch level {
        case .error: .error
        case .warn: .warning
        case .info: .info
        case .debug, .trace: .debug
        }
    }

    init(_ severity: LKRTCLoggingSeverity) {
        self = switch severity {
        case .error: .error
        case .warning: .warning
        case .info: .info
        case .verbose, .none: .debug
        @unknown default: .debug
        }
    }
}

extension LKRTCLoggingSeverity {
    var osLogType: OSLogType {
        switch self {
        case .verbose: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        case .none: .debug
        @unknown default: .debug
        }
    }
}

extension LogForwardLevel {
    var osLogType: OSLogType {
        switch self {
        case .error: .error
        case .warn: .default
        case .info: .info
        case .debug, .trace: .debug
        @unknown default: .debug
        }
    }
}
