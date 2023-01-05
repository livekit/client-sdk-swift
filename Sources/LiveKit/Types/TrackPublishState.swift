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

/// A enum that represents the published state of a ``LocalTrackPublication``.
public enum TrackPublishState {
    /// Not published yet, has been unpublished, or an error occured while publishing or un-publishing.
    /// `error` wil be non-nil if an error occurred while publishing.
    case notPublished(error: Error? = nil)
    /// In the process of publishing or unpublishing.
    case busy(isPublishing: Bool = true)
    /// Sucessfully published.
    case published(LocalTrackPublication)

    /// Checks whether the state is ``TrackPublishState/published(_:)`` regardless of the error value.
    public var isPublished: Bool {
        guard case .published = self else { return false }
        return true
    }

    /// Checks whether the state is ``TrackPublishState/busy(isPublishing:)`` regardless of the `isPublishing` value.
    public var isBusy: Bool {
        guard case .busy = self else { return false }
        return true
    }
}

/// Equality extension for ``TrackPublishState``.
extension TrackPublishState: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.notPublished, .notPublished),
             (.busy, .busy), (.published, .published): return true
        default: return false
        }
    }
}
