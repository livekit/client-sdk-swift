/*
 * Copyright 2022 LiveKit
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
import Logging

/// Allows to extend with custom `log` method which automatically captures current type (class name).
public protocol Loggable {

}

private var _scopedMetadataKey = "scopedMetadata"

public typealias ScopedMetadata = CustomStringConvertible
internal typealias ScopedMetadataContainer = [String: ScopedMetadata]

public extension Loggable {

    /// attach logger metadata to this instance that will be automatically included in every log onward
    func set(loggerMetadata data: ScopedMetadata?, for key: String) {
        var _data = _scopedMetadata()
        _data[key] = data
        objc_setAssociatedObject(self, &_scopedMetadataKey, _data, .OBJC_ASSOCIATION_RETAIN)
    }

    private func _scopedMetadata() -> ScopedMetadataContainer {
        (objc_getAssociatedObject(self, &_scopedMetadataKey) as? ScopedMetadataContainer) ?? ScopedMetadataContainer()
    }

    /// Automatically captures current type (class name) to ``Logger.Metadata``
    internal func log(_ message: Logger.Message? = nil,
                      _ level: Logger.Level = .debug,
                      file: String = #file,
                      type type_: Any.Type? = nil,
                      function: String = #function,
                      line: UInt = #line) {

        logger.log(message ?? "",
                   level,
                   file: file,
                   type: type_ ?? type(of: self),
                   function: function,
                   line: line,
                   metaData: _scopedMetadata())
    }
}

internal extension Logger {

    /// Adds `type` param to capture current type (usually class)
    func log(_ message: Logger.Message,
             _ level: Logger.Level = .debug,
             source: @autoclosure () -> String? = nil,
             file: String = #file,
             type: Any.Type,
             function: String = #function,
             line: UInt = #line,
             metaData: ScopedMetadataContainer = ScopedMetadataContainer()) {

        func _buildScopedMetadataString() -> String {
            guard !metaData.isEmpty else { return "" }
            return " [\(metaData.map { "\($0): \($1)" }.joined(separator: ", "))]"
        }

        log(level: level,
            "\(String(describing: type)).\(function) \(message)\(_buildScopedMetadataString())",
            file: file,
            function: function,
            line: line)
    }
}
