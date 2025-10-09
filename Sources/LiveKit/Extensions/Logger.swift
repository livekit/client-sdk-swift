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

/// Allows to extend with custom `log` method which automatically captures current type (class name).
public protocol Loggable {}

public typealias ScopedMetadata = CustomStringConvertible
public typealias ScopedMetadataContainer = [String: ScopedMetadata]

extension Loggable {
    /// Automatically captures current type (class name) to ``Logger.Metadata``
    func log(_ message: CustomStringConvertible? = nil,
             _ level: LiveKitSDK.LogLevel = .debug,
             file: String = #fileID,
             type type_: Any.Type? = nil,
             function: String = #function,
             line: UInt = #line)
    {
        LiveKitSDK.state.logHandler.log(message ?? "",
                                        level,
                                        file: file,
                                        type: type_ ?? type(of: self),
                                        function: function,
                                        line: line)
    }
}

public class LogHandler {
    public func log(_: CustomStringConvertible,
                    _: LiveKitSDK.LogLevel = .debug,
                    source _: @autoclosure () -> String? = nil,
                    file _: String = #fileID,
                    type _: Any.Type,
                    function _: String = #function,
                    line _: UInt = #line,
                    metaData _: ScopedMetadataContainer = ScopedMetadataContainer())
    {
        // no-op
    }
}

public class OSLogHandler: LogHandler {
    let osLog = OSLog(subsystem: "io.livekit.sdk", category: "LiveKit")

    override public func log(_ message: any CustomStringConvertible, _ level: LiveKitSDK.LogLevel = .debug, source _: @autoclosure () -> String? = nil, file _: String = #fileID, type: any Any.Type, function: String = #function, line _: UInt = #line, metaData: ScopedMetadataContainer = ScopedMetadataContainer()) {
        func _buildScopedMetadataString() -> String {
            guard !metaData.isEmpty else { return "" }
            return " [\(metaData.map { "\($0): \($1)" }.joined(separator: ", "))]"
        }

        let formattedMessage = "\(String(describing: type)).\(function) \(message)\(_buildScopedMetadataString())"
        os_log("%{public}@", log: osLog, type: level.osLogType, formattedMessage)
    }
}

extension OSLog {
    /// Adds `type` param to capture current type (usually class)
    public func log(_ message: CustomStringConvertible,
                    _ level: LiveKitSDK.LogLevel = .debug,
                    source _: @autoclosure () -> String? = nil,
                    file _: String = #fileID,
                    type: Any.Type,
                    function: String = #function,
                    line _: UInt = #line,
                    metaData: ScopedMetadataContainer = ScopedMetadataContainer())
    {
        func _buildScopedMetadataString() -> String {
            guard !metaData.isEmpty else { return "" }
            return " [\(metaData.map { "\($0): \($1)" }.joined(separator: ", "))]"
        }

        let formattedMessage = "\(String(describing: type)).\(function) \(message)\(_buildScopedMetadataString())"
        os_log("%{public}@", log: self, type: level.osLogType, formattedMessage)
    }

    func trace(_ message: CustomStringConvertible, file _: String = #fileID, function _: String = #function, line _: UInt = #line) {
        os_log("%{public}@", log: self, type: .debug, "\(message)")
    }

    func debug(_ message: CustomStringConvertible, file _: String = #fileID, function _: String = #function, line _: UInt = #line) {
        os_log("%{public}@", log: self, type: .debug, "\(message)")
    }

    func info(_ message: CustomStringConvertible, file _: String = #fileID, function _: String = #function, line _: UInt = #line) {
        os_log("%{public}@", log: self, type: .info, "\(message)")
    }

    func warning(_ message: CustomStringConvertible, file _: String = #fileID, function _: String = #function, line _: UInt = #line) {
        os_log("%{public}@", log: self, type: .default, "\(message)")
    }

    func error(_ message: CustomStringConvertible, file _: String = #fileID, function _: String = #function, line _: UInt = #line) {
        os_log("%{public}@", log: self, type: .error, "\(message)")
    }
}
