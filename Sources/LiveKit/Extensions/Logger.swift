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

import Foundation
import OSLog
internal import LiveKitWebRTC

// MARK: - Level

public enum LogLevel: Int, Sendable, Comparable {
    case trace // drop?
    case debug
    case info
    case warning
    case error

    var osLogType: OSLogType {
        switch self {
        case .trace: .debug
        case .debug: .debug
        case .info: .info
        case .warning: .default
        case .error: .error
        }
    }

    var rtcSeverity: LKRTCLoggingSeverity {
        switch self {
        case .trace: .verbose
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
        case .none: .error
        @unknown default: .error
        }
    }
}

// MARK: - Loggable

/// Allows to extend with custom `log` method which automatically captures current type (class name).
public protocol Loggable {}

public typealias ScopedMetadata = CustomStringConvertible
public typealias ScopedMetadataContainer = [String: ScopedMetadata]

extension Loggable {
    func log(_ message: CustomStringConvertible? = nil,
             _ level: LogLevel = .debug,
             file: String = #fileID,
             function: String = #function,
             line: UInt = #line)
    {
        logger.log(message ?? "",
                   level,
                   file: file,
                   type: type(of: self),
                   function: function,
                   line: line)
    }
}

// MARK: - Handler

public protocol LogHandler: Sendable {
    func log(
        _ message: CustomStringConvertible,
        _ level: LogLevel,
        source: () -> String?,
        file: String,
        type: Any.Type,
        function: String,
        line: UInt,
        metaData: ScopedMetadataContainer
    )
}

public extension LogHandler {
    func log(
        _ message: CustomStringConvertible,
        _ level: LogLevel = .debug,
        source: @autoclosure () -> String? = nil,
        file: String = #fileID,
        type: Any.Type,
        function: String = #function,
        line: UInt = #line,
        metaData: ScopedMetadataContainer = ScopedMetadataContainer()
    ) {
        log(message, level, source: source, file: file, type: type, function: function, line: line, metaData: metaData)
    }
}

extension LogHandler {
    func error(_ message: CustomStringConvertible,
               file: String = #fileID,
               type: Any.Type = Any.self,
               function: String = #function,
               line: UInt = #line)
    {
        log(message, .error, file: file, type: type, function: function, line: line)
    }

    func warning(_ message: CustomStringConvertible,
                 file: String = #fileID,
                 type: Any.Type = Any.self,
                 function: String = #function,
                 line: UInt = #line)
    {
        log(message, .warning, file: file, type: type, function: function, line: line)
    }

    func info(_ message: CustomStringConvertible,
              file: String = #fileID,
              type: Any.Type = Any.self,
              function: String = #function,
              line: UInt = #line)
    {
        log(message, .info, file: file, type: type, function: function, line: line)
    }

    func debug(_ message: CustomStringConvertible,
               file: String = #fileID,
               type: Any.Type = Any.self,
               function: String = #function,
               line: UInt = #line)
    {
        log(message, .debug, file: file, type: type, function: function, line: line)
    }

    func trace(_ message: CustomStringConvertible,
               file: String = #fileID,
               type: Any.Type = Any.self,
               function: String = #function,
               line: UInt = #line)
    {
        log(message, .trace, file: file, type: type, function: function, line: line)
    }
}

public struct DisabledLogHandler: LogHandler {
    public func log(
        _: CustomStringConvertible,
        _: LogLevel,
        source _: () -> String?,
        file _: String,
        type _: Any.Type,
        function _: String,
        line _: UInt,
        metaData _: ScopedMetadataContainer
    ) {}
}

public final class OSLogHandler: LogHandler {
    private let osLog = OSLog(subsystem: "io.livekit.sdk", category: "LiveKit")
    private let rtcLog = OSLog(subsystem: "io.livekit.sdk", category: "WebRTC")
    private let rtcLogger = LKRTCCallbackLogger()

    private let level: LogLevel

    public init(minLevel: LogLevel = .info, rtc: Bool = false) {
        level = minLevel

        guard rtc else { return }

        rtcLogger.severity = level.rtcSeverity
        rtcLogger.start { [rtcLog] message, severity in
            os_log("%{public}@", log: rtcLog, type: severity.osLogType, message)
        }
    }

    deinit {
        rtcLogger.stop()
    }

    public func log(
        _ message: CustomStringConvertible,
        _ level: LogLevel,
        source _: () -> String?,
        file _: String,
        type: Any.Type,
        function: String,
        line _: UInt,
        metaData: ScopedMetadataContainer
    ) {
        guard level >= self.level else { return }

        func buildScopedMetadataString() -> String {
            guard !metaData.isEmpty else { return "" }
            return " [\(metaData.map { "\($0): \($1)" }.joined(separator: ", "))]"
        }

        let formattedMessage = "\(String(describing: type)).\(function) \(message)\(buildScopedMetadataString())"
        os_log("%{public}@", log: osLog, type: level.osLogType, formattedMessage)
    }
}
