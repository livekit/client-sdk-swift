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

public extension Track {
    @objc(TrackSid)
    final class Sid: NSObject, Codable, Sendable {
        @objc
        public let stringValue: String

        init(from stringValue: String) {
            self.stringValue = stringValue
        }

        override public func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Self else { return false }
            return stringValue == other.stringValue
        }

        override public var hash: Int {
            var hasher = Hasher()
            stringValue.hash(into: &hasher)
            return hasher.finalize()
        }

        override public var description: String {
            stringValue
        }
    }
}
