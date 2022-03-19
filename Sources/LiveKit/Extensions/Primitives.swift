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

extension String {

    internal func unpack() -> (sid: Sid, trackId: String) {
        let parts = split(separator: "|")
        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]))
        }
        return (self, "")
    }

}

extension Bool {

    internal func toString() -> String {
        self ? "true" : "false"
    }
}

extension URL {

    internal var isSecure: Bool {
        scheme == "https" || scheme == "wss"
    }
}
