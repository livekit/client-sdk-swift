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

struct ParseStreamIdResult {
    let participantSid: Participant.Sid
    let streamId: String?
    let trackId: Track.Sid?
}

func parse(streamId: String) -> ParseStreamIdResult {
    let parts = streamId.split(separator: "|")
    if parts.count >= 2 {
        let p1String = String(parts[1])
        let p1IsTrackId = p1String.starts(with: "TR_")
        return ParseStreamIdResult(participantSid: Participant.Sid(from: String(parts[0])),
                                   streamId: p1IsTrackId ? nil : p1String,
                                   trackId: p1IsTrackId ? Track.Sid(from: p1String) : nil)
    }
    return ParseStreamIdResult(participantSid: Participant.Sid(from: streamId),
                               streamId: nil,
                               trackId: nil)
}

extension Bool {
    func toString() -> String {
        self ? "true" : "false"
    }
}

public extension Double {
    func rounded(to places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
