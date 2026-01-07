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

import OSLog
internal import LiveKitWebRTC
internal import LiveKitUniFFI

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
        metaData: ScopedMetadataContainer
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
        metaData: ScopedMetadataContainer = ScopedMetadataContainer()
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
        metaData _: ScopedMetadataContainer
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
        metaData _: ScopedMetadataContainer
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

    private lazy var rtcLogger = LKRTCCallbackLogger()
    private var ffiTask: AnyTaskCancellable?

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

    deinit {
        rtcLogger.stop()
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
        metaData: ScopedMetadataContainer
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

        rtcLogger.severity = minLevel.rtcSeverity
        rtcLogger.start { message, severity in
            os_log("%{public}@", log: rtcLog, type: severity.osLogType, message)
        }
    }

    private func startFFILogForwarding(minLevel: LogLevel) {
        Task(priority: .utility) { [weak self] in
            guard let self else { return } // don't initialize global level when releasing
            logForwardBootstrap(level: minLevel.logForwardFilter)

            let ffiLog = OSLog(subsystem: Self.subsystem, category: "FFI")

            ffiTask = AsyncStream(unfolding: logForwardReceive).subscribe(self, priority: .utility) { _, entry in
                os_log("%{public}@", log: ffiLog, type: entry.level.osLogType, "\(entry.target) \(entry.message)")
            }
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
        sharedLogger.log(message ?? "",
                         level,
                         file: file,
                         type: Self.self,
                         function: function,
                         line: line)
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
        #if swift(>=6.0)
        @unknown default: .debug
        #endif
        }
    }
}
