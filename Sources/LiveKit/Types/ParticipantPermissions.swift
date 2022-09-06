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
public class ParticipantPermissions: NSObject {

    /// ``Participant`` can subscribe to tracks in the room
    @objc
    public let canSubscribe: Bool

    /// ``Participant`` can publish new tracks to room
    @objc
    public let canPublish: Bool

    /// ``Participant`` can publish data
    @objc
    public let canPublishData: Bool

    /// ``Participant`` is hidden to others
    @objc
    public let hidden: Bool

    /// Indicates it's a recorder instance
    @objc
    public let recorder: Bool

    internal init(canSubscribe: Bool = false,
                  canPublish: Bool = false,
                  canPublishData: Bool = false,
                  hidden: Bool = false,
                  recorder: Bool = false) {

        self.canSubscribe = canSubscribe
        self.canPublish = canPublish
        self.canPublishData = canPublishData
        self.hidden = hidden
        self.recorder = recorder
    }

    // MARK: - Equal

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return self.canSubscribe == other.canSubscribe &&
            self.canPublish == other.canPublish &&
            self.canPublishData == other.canPublishData &&
            self.hidden == other.hidden &&
            self.recorder == other.recorder
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(canSubscribe)
        hasher.combine(canPublish)
        hasher.combine(canPublishData)
        hasher.combine(hidden)
        hasher.combine(recorder)
        return hasher.finalize()
    }
}

extension Livekit_ParticipantPermission {

    func toLKType() -> ParticipantPermissions {
        ParticipantPermissions(canSubscribe: canSubscribe,
                               canPublish: canPublish,
                               canPublishData: canPublishData,
                               hidden: hidden,
                               recorder: recorder)
    }
}
