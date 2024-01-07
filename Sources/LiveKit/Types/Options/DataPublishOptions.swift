/*
 * Copyright 2024 LiveKit
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
public class DataPublishOptions: NSObject, PublishOptions {
    @objc
    public let name: String?

    @objc
    public let destinationIdentities: [Identity]

    @objc
    public let topic: String?

    public init(name: String? = nil,
                destinationIdentities: [Identity] = [],
                topic: String? = nil)
    {
        self.name = name
        self.destinationIdentities = destinationIdentities
        self.topic = topic
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return name == other.name &&
            destinationIdentities == other.destinationIdentities &&
            topic == other.topic
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(destinationIdentities)
        hasher.combine(topic)
        return hasher.finalize()
    }
}
