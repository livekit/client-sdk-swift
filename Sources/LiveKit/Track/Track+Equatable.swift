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

// MARK: - Equatable for NSObject

public extension Track {
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return mediaTrack.trackId == other.mediaTrack.trackId
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(mediaTrack.trackId)
        return hasher.finalize()
    }
}
