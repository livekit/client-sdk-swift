/*
 * Copyright 2025 LiveKit
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

// MARK: - Logger

public typealias ScopedMetadata = CustomStringConvertible
public typealias ScopedMetadataContainer = [String: ScopedMetadata]

public protocol Logger: Sendable {
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

/// A logger that logs to OSLog
/// - Parameter minLevel: The minimum level to log
/// - Parameter rtc: Whether to log WebRTC output
open class OSLogger: Logger, @unchecked Sendable {
    private static let subsystem = "io.livekit.sdk"

    private let queue = DispatchQueue(label: "io.livekit.oslogger", qos: .utility)
    private var logs: [String: OSLog] = [:]

    private lazy var rtcLogger = LKRTCCallbackLogger()

    private let minLevel: LogLevel

    public init(minLevel: LogLevel = .info, rtc: Bool = false) {
        self.minLevel = minLevel

        guard rtc else { return }

        let rtcLog = OSLog(subsystem: Self.subsystem, category: "WebRTC")
        rtcLogger.severity = minLevel.rtcSeverity
        rtcLogger.start { message, severity in
            os_log("%{public}@", log: rtcLog, type: severity.osLogType, message)
        }
    }

    deinit {
        rtcLogger.stop()
    }

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
public enum LogLevel: Int, Sendable, Comparable {
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

    @inlinable
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
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
