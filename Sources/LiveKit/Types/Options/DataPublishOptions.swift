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
public final class DataPublishOptions: NSObject, PublishOptions, Sendable {
    @objc
    public let name: String?

    /// The identities of participants who will receive the message, will be sent to every one if empty.
    @objc
    public let destinationIdentities: [Participant.Identity]

    /// The topic under which the message gets published.
    @objc
    public let topic: String?

    /// Whether to send this as reliable or lossy.
    /// For data that you need delivery guarantee (such as chat messages) set to true (reliable).
    /// For data that should arrive as quickly as possible, but you are ok with dropped packets, set to false (lossy).
    @objc
    public let reliable: Bool

    public init(name: String? = nil,
                destinationIdentities: [Participant.Identity] = [],
                topic: String? = nil,
                reliable: Bool = false)
    {
        self.name = name
        self.destinationIdentities = destinationIdentities
        self.topic = topic
        self.reliable = reliable
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return name == other.name &&
            destinationIdentities == other.destinationIdentities &&
            topic == other.topic &&
            reliable == other.reliable
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(destinationIdentities)
        hasher.combine(topic)
        hasher.combine(reliable)
        return hasher.finalize()
    }
}
