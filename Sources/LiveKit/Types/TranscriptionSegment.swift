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

@objc
public final class TranscriptionSegment: NSObject, Sendable {
    public let id: String
    public let text: String
    public let language: String
    public let firstReceivedTime: Date
    public let lastReceivedTime: Date
    public let isFinal: Bool

    init(id: String,
         text: String,
         language: String,
         firstReceivedTime: Date,
         lastReceivedTime: Date,
         isFinal: Bool)
    {
        self.id = id
        self.text = text
        self.language = language
        self.firstReceivedTime = firstReceivedTime
        self.lastReceivedTime = lastReceivedTime
        self.isFinal = isFinal
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return id == other.id
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        return hasher.finalize()
    }
}
