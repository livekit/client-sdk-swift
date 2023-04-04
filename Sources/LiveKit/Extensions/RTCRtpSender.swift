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
import WebRTC

extension RTCRtpSender: Loggable {

    internal func setPublishingLayers(subscribedQualities: [Livekit_SubscribedQuality]) {

        let _parameters = self.parameters
        let encodings = _parameters.encodings

        var hasChanged = false
        for quality in subscribedQualities {

            var rid: String
            switch quality.quality {
            case Livekit_VideoQuality.high: rid = "f"
            case Livekit_VideoQuality.medium: rid = "h"
            case Livekit_VideoQuality.low: rid = "q"
            default: continue
            }

            guard let encoding = encodings.first(where: { $0.rid == rid }) else {
                continue
            }

            if encoding.isActive != quality.enabled {
                hasChanged = true
                encoding.isActive = quality.enabled
                log("setting layer \(quality.quality) to \(quality.enabled)", .info)
            }
        }

        // Non simulcast streams don't have rids, handle here.
        if encodings.count == 1 && subscribedQualities.count >= 1 {
            let encoding = encodings[0]
            let quality = subscribedQualities[0]

            if encoding.isActive != quality.enabled {
                hasChanged = true
                encoding.isActive = quality.enabled
                log("setting layer \(quality.quality) to \(quality.enabled)", .info)
            }
        }

        if hasChanged {
            self.parameters = _parameters
        }
    }
}
