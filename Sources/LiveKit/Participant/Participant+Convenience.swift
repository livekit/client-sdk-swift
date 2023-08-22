/*
 * Copyright 2023 LiveKit
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

extension Participant {

    public var firstCameraPublication: TrackPublication? {
        videoTracks.first(where: { $0.source == .camera })
    }

    public var firstScreenSharePublication: TrackPublication? {
        videoTracks.first(where: { $0.source == .screenShareVideo })
    }

    public var firstAudioPublication: TrackPublication? {
        audioTracks.first
    }

    public var firstTrackEncryptionType: EncryptionType {
        if let pub = firstCameraPublication {
            return pub.encryptionType
        } else if let pub = firstScreenSharePublication {
            return pub.encryptionType
        } else if let pub = firstAudioPublication {
            return pub.encryptionType
        } else {
            return .none
        }
    }

    public var firstCameraVideoTrack: VideoTrack? {
        guard let pub = firstCameraPublication, !pub.muted, pub.subscribed,
              let track = pub.track else { return nil }
        return track as? VideoTrack
    }

    public var firstScreenShareVideoTrack: VideoTrack? {
        guard let pub = firstScreenSharePublication, !pub.muted, pub.subscribed,
              let track = pub.track else { return nil }
        return track as? VideoTrack
    }

    public var firstAudioTrack: AudioTrack? {
        guard let pub = firstAudioPublication, !pub.muted,
              let track = pub.track else { return nil }
        return track as? AudioTrack
    }
}
