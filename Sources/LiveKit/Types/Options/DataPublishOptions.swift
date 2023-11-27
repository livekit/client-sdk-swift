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

@objc
public class DataPublishOptions: NSObject, PublishOptions {

    @objc
    public let name: String?

    @objc
    public let destinations: [Sid]

    @objc
    public let topic: String?

    public init(name: String? = nil,
                destinations: [String] = [],
                topic: String? = nil) {

        self.name = name
        self.destinations = destinations
        self.topic = topic
    }

    // MARK: - Equal

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return self.name == other.name &&
            self.destinations == other.destinations &&
            self.topic == other.topic
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(destinations)
        hasher.combine(topic)
        return hasher.finalize()
    }
}
