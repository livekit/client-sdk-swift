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

extension String {
    /// Simply return nil if String is empty
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var byteLength: Int {
        utf8.count
    }

    /// The longest prefix of characters whose UTF-8 encoding fits in `maxBytes`.
    func truncate(maxBytes: Int) -> String {
        if byteLength <= maxBytes {
            return self
        }

        var end = startIndex
        var used = 0
        while end < endIndex {
            let next = index(after: end)
            let width = utf8.distance(from: end, to: next)
            if used + width > maxBytes { break }
            used += width
            end = next
        }
        return String(self[..<end])
    }

    /// The path extension, if any, of the string as interpreted as a path.
    var pathExtension: String? {
        let pathExtension = (self as NSString).pathExtension
        return pathExtension.isEmpty ? nil : pathExtension
    }
}
