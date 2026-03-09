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

@objcMembers
public class ParticipantPermissions: NSObject, @unchecked Sendable {
    /// ``Participant`` can subscribe to tracks in the room
    public let canSubscribe: Bool

    /// ``Participant`` can publish new tracks to room
    public let canPublish: Bool

    /// ``Participant`` can publish data
    public let canPublishData: Bool

    /// ``Participant`` can publish allowed sources
    public let canPublishSources: Set<Track.Source.RawValue>

    /// ``Participant`` is hidden to others
    public let hidden: Bool

    /// Indicates it's a recorder instance
    public let recorder: Bool

    /// Indicates participant can update own metadata and attributes
    public let canUpdateMetadata: Bool

    /// Indicates participant can subscribe to metrics
    public let canSubscribeMetrics: Bool

    init(canSubscribe: Bool = false,
         canPublish: Bool = false,
         canPublishData: Bool = false,
         canPublishSources: Set<Track.Source> = [],
         hidden: Bool = false,
         recorder: Bool = false,
         canUpdateMetadata: Bool = false,
         canSubscribeMetrics: Bool = false)
    {
        self.canSubscribe = canSubscribe
        self.canPublish = canPublish
        self.canPublishData = canPublishData
        self.canPublishSources = Set(canPublishSources.map(\.rawValue))
        self.hidden = hidden
        self.recorder = recorder
        self.canUpdateMetadata = canUpdateMetadata
        self.canSubscribeMetrics = canSubscribeMetrics
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return canSubscribe == other.canSubscribe &&
            canPublish == other.canPublish &&
            canPublishData == other.canPublishData &&
            canPublishSources == other.canPublishSources &&
            hidden == other.hidden &&
            recorder == other.recorder &&
            canUpdateMetadata == other.canUpdateMetadata &&
            canSubscribeMetrics == other.canSubscribeMetrics
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(canSubscribe)
        hasher.combine(canPublish)
        hasher.combine(canPublishData)
        hasher.combine(canPublishSources)
        hasher.combine(hidden)
        hasher.combine(recorder)
        hasher.combine(canUpdateMetadata)
        hasher.combine(canSubscribeMetrics)
        return hasher.finalize()
    }
}

extension Livekit_ParticipantPermission {
    func toLKType() -> ParticipantPermissions {
        ParticipantPermissions(canSubscribe: canSubscribe,
                               canPublish: canPublish,
                               canPublishData: canPublishData,
                               canPublishSources: Set(canPublishSources.map { $0.toLKType() }),
                               hidden: hidden,
                               recorder: recorder,
                               canUpdateMetadata: canUpdateMetadata,
                               canSubscribeMetrics: canSubscribeMetrics)
    }
}
