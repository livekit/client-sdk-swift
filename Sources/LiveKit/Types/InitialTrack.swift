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

/// A local media track and its publish options to publish while connecting to a room.
@objcMembers
public final class InitialTrack: NSObject, Sendable {
    /// The audio or video track to publish.
    public let track: LocalTrack
    /// Options used for this publication, or the room's defaults when omitted.
    public let options: TrackPublishOptions?

    /// Creates a publication to pass to ``Room/connect(url:token:connectOptions:roomOptions:publishTracks:)``.
    public init(track: LocalTrack, options: TrackPublishOptions? = nil) {
        self.track = track
        self.options = options
    }
}
