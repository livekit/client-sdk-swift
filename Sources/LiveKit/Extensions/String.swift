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

extension String {
    /// Simply return nil if String is empty
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var byteLength: Int {
        data(using: .utf8)?.count ?? 0
    }

    func truncate(maxBytes: Int) -> String {
        if byteLength <= maxBytes {
            return self
        }

        var low = 0
        var high = count

        while low < high {
            let mid = (low + high + 1) / 2
            let substring = String(prefix(mid))
            if substring.byteLength <= maxBytes {
                low = mid
            } else {
                high = mid - 1
            }
        }

        return String(prefix(low))
    }

    /// The path extension, if any, of the string as interpreted as a path.
    var pathExtension: String? {
        let pathExtension = (self as NSString).pathExtension
        return pathExtension.isEmpty ? nil : pathExtension
    }
}
