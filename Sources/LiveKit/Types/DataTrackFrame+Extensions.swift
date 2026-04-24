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

internal import LiveKitUniFFI

extension DataTrackFrame {
    /// Creates a frame with the current Unix timestamp in milliseconds.
    static func now(payload: Data) -> DataTrackFrame {
        DataTrackFrame(
            payload: payload,
            userTimestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// Time elapsed since the frame's timestamp, if present.
    var latency: TimeInterval? {
        guard let ts = userTimestamp else { return nil }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        guard now >= ts else { return nil }
        return TimeInterval(now - ts) / 1000.0
    }
}
