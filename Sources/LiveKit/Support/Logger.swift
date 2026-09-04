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

        if rtc {
            startRTCLogForwarding(minLevel: minLevel)
        }

        if ffi {
            startFFILogForwarding(minLevel: minLevel)
        }
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

            os_log("%{public}@", log: getOSLog(for: type), type: level.osLogType, "\(type).\(function) \(message)\(metadata)")
        }
    }

    private func startRTCLogForwarding(minLevel: LogLevel) {
        let rtcLog = OSLog(subsystem: Self.subsystem, category: "WebRTC")
        LogForwarders.rtc.start(minLevel: minLevel) { entry in
            os_log("%{public}@", log: rtcLog, type: entry.severity.osLogType, entry.message)
        }
    }

    private func startFFILogForwarding(minLevel: LogLevel) {
        let ffiLog = OSLog(subsystem: Self.subsystem, category: "FFI")
        LogForwarders.ffi.start(minLevel: minLevel) { entry in
            os_log("%{public}@", log: ffiLog, type: entry.level.osLogType, "\(entry.target) \(entry.message)")
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
        // Telemetry first, so the app's logger cannot take its place. Warn/error only leave the
        // device (design doc); captured here synchronously — timestamp, ambient span — then handed over.
        if level >= .warning {
            Telemetry.log(message?.description ?? "", level: level, source: .sdk,
                          type: String(describing: Self.self), function: "\(function)", file: "\(file)", line: line)
        }
        sharedLogger.log(message ?? "",
                         level,
                         file: file,
                         type: Self.self,
                         function: function,
                         line: line)
    }
}

// MARK: - External log sources

/// A log source outside the SDK's own logger — the Rust core, WebRTC — with a single subscription
/// per process: drained once and fanned out to the console handlers that registered and, at
/// warn/error, to telemetry. Started by whoever needs it first (`OSLogger`, or telemetry when the
/// app uses its own logger), at the lowest level asked for.
final class LogForwarder<Entry: Sendable>: @unchecked Sendable {
    typealias Handler = @Sendable (Entry) -> Void

    /// The parts of an entry telemetry records.
    struct Record {
        let level: LogLevel
        let message: String
        let type: String
        let file: String
        let line: UInt
    }

    private struct State {
        var level: LogLevel?
        var handlers: [Handler] = []
    }

    private let state = StateSync(State())
    private let source: Telemetry.LogSource
    /// Begin producing entries at a level, delivering each through the closure. Called once.
    private let begin: @Sendable (LogLevel, @escaping Handler) -> Void
    /// Lower the level of a running source.
    private let adjust: @Sendable (LogLevel) -> Void
    private let record: @Sendable (Entry) -> Record

    init(source: Telemetry.LogSource,
         begin: @escaping @Sendable (LogLevel, @escaping Handler) -> Void,
         adjust: @escaping @Sendable (LogLevel) -> Void,
         record: @escaping @Sendable (Entry) -> Record)
    {
        self.source = source
        self.begin = begin
        self.adjust = adjust
        self.record = record
    }

    func start(minLevel: LogLevel, handler: Handler? = nil) {
        let (previous, lower) = state.mutate { state -> (LogLevel?, Bool) in
            if let handler { state.handlers.append(handler) }
            let previous = state.level
            let lower = previous.map { minLevel < $0 } ?? true
            if lower { state.level = minLevel }
            return (previous, lower)
        }
        if previous == nil {
            begin(minLevel) { [self] entry in deliver(entry) }
        } else if lower {
            adjust(minLevel)
        }
    }

    private func deliver(_ entry: Entry) {
        for handler in state.copy().handlers {
            handler(entry)
        }
        let record = record(entry)
        if record.level >= .warning {
            Telemetry.log(record.message, level: record.level, source: source,
                          type: record.type, function: "", file: record.file, line: record.line)
        }
    }
}

enum LogForwarders {
    /// The Rust core: `logForwardReceive` has one consumer.
    static let ffi = LogForwarder<LogForwardEntry>(
        source: .ffi,
        begin: { level, deliver in
            logForwardBootstrap(level: level.logForwardFilter)
            Task(priority: .utility) {
                while let entry = await logForwardReceive() {
                    deliver(entry)
                }
            }
        },
        adjust: { logForwardBootstrap(level: $0.logForwardFilter) },
        record: { entry in
            .init(level: entry.level == .error ? .error : entry.level == .warn ? .warning : .debug,
                  message: "\(entry.target) \(entry.message)", type: entry.target,
                  file: entry.file ?? "", line: entry.line.map { UInt($0) } ?? 0)
        },
    )

    /// WebRTC: one callback logger for the process.
    static let rtc: LogForwarder<(message: String, severity: LKRTCLoggingSeverity)> = {
        let logger = LKRTCCallbackLogger()
        return LogForwarder(
            source: .webrtc,
            begin: { level, deliver in
                logger.severity = level.rtcSeverity
                logger.start { message, severity in deliver((message, severity)) }
            },
            adjust: { logger.severity = $0.rtcSeverity },
            record: { entry in
                .init(level: entry.severity == .error ? .error : entry.severity == .warning ? .warning : .debug,
                      message: entry.message.trimmingCharacters(in: .whitespacesAndNewlines), type: "WebRTC",
                      file: "", line: 0)
            },
        )
    }()
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
