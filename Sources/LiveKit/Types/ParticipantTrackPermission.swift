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
public final class ParticipantTrackPermission: NSObject, Sendable {
    /**
     * The participant id this permission applies to.
     */
    public let participantSid: String

    /**
     * If set to true, the target participant can subscribe to all tracks from the local participant.
     *
     * Takes precedence over ``allowedTrackSids``.
     */
    let allTracksAllowed: Bool

    /**
     * The list of track ids that the target participant can subscribe to.
     */
    let allowedTrackSids: [String]

    public init(participantSid: String,
                allTracksAllowed: Bool,
                allowedTrackSids: [String] = [String]())
    {
        self.participantSid = participantSid
        self.allTracksAllowed = allTracksAllowed
        self.allowedTrackSids = allowedTrackSids
    }
}

extension ParticipantTrackPermission {
    func toPBType() -> Livekit_TrackPermission {
        Livekit_TrackPermission.with {
            $0.participantSid = self.participantSid
            $0.allTracks = self.allTracksAllowed
            $0.trackSids = self.allowedTrackSids
        }
    }
}
