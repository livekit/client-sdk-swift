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

// MARK: - Handler

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

/// A loggerthat logs to OSLog
/// - Parameter minLevel: The minimum level to log
/// - Parameter rtc: Whether to log WebRTC output
public final class OSLogger: Logger {
    private let osLog = OSLog(subsystem: "io.livekit.sdk", category: "LiveKit")
    private let rtcLog = OSLog(subsystem: "io.livekit.sdk", category: "WebRTC")
    private let rtcLogger = LKRTCCallbackLogger()

    private let minLevel: LogLevel

    public init(minLevel: LogLevel = .info, rtc: Bool = false) {
        self.minLevel = minLevel

        guard rtc else { return }

        rtcLogger.severity = minLevel.rtcSeverity
        rtcLogger.start { [rtcLog] message, severity in
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

        func buildScopedMetadataString() -> String {
            guard !metaData.isEmpty else { return "" }
            return " [\(metaData.map { "\($0): \($1)" }.joined(separator: ", "))]"
        }

        let formattedMessage = "\(type).\(function) \(message())\(buildScopedMetadataString())"
        os_log("%{public}@", log: osLog, type: level.osLogType, formattedMessage)
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
        logger.log(message ?? "",
                   level,
                   file: file,
                   type: Self.self,
                   function: function,
                   line: line)
    }

    static func log(_ message: CustomStringConvertible? = nil,
                    _ level: LogLevel = .debug,
                    file: StaticString = #fileID,
                    function: StaticString = #function,
                    line: UInt = #line)
    {
        logger.log(message ?? "",
                   level,
                   file: file,
                   type: Self.self,
                   function: function,
                   line: line)
    }
}

// MARK: - Level

@frozen public enum LogLevel: Int, Sendable, Comparable {
    case debug
    case info
    case warning
    case error

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
