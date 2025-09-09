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

public extension Participant {
    var firstCameraPublication: TrackPublication? {
        videoTracks.first(where: { $0.source == .camera })
    }

    var firstScreenSharePublication: TrackPublication? {
        videoTracks.first(where: { $0.source == .screenShareVideo })
    }

    var firstAudioPublication: TrackPublication? {
        audioTracks.first
    }

    var firstTrackEncryptionType: EncryptionType {
        if let pub = firstCameraPublication {
            pub.encryptionType
        } else if let pub = firstScreenSharePublication {
            pub.encryptionType
        } else if let pub = firstAudioPublication {
            pub.encryptionType
        } else {
            .none
        }
    }

    var firstCameraVideoTrack: VideoTrack? {
        guard let pub = firstCameraPublication, !pub.isMuted, pub.isSubscribed,
              let track = pub.track else { return nil }
        return track as? VideoTrack
    }

    var firstScreenShareVideoTrack: VideoTrack? {
        guard let pub = firstScreenSharePublication, !pub.isMuted, pub.isSubscribed,
              let track = pub.track else { return nil }
        return track as? VideoTrack
    }

    var firstAudioTrack: AudioTrack? {
        guard let pub = firstAudioPublication, !pub.isMuted,
              let track = pub.track else { return nil }
        return track as? AudioTrack
    }
}
