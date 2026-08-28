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

internal import LiveKitWebRTC

extension LKRTCRtpSender: Loggable {
    /// Sets the degradation preference on this sender.
    ///
    /// Degradation preference is a property of the sender, not of the track, so every sender
    /// publishing a track needs it applied separately. A backup codec publishes over its own
    /// sender, which would otherwise let WebRTC resolve a preference implicitly from the native
    /// source and diverge from the primary encoder.
    @RTC
    func set(degradationPreference: LKRTCDegradationPreference) {
        // Changing params directly doesn't work so we need to update params and set it back to sender.parameters
        let _parameters = parameters
        _parameters.degradationPreference = NSNumber(value: degradationPreference.rawValue)
        parameters = _parameters
    }

    // ...
    @RTC
    func _set(subscribedQualities qualities: [Livekit_SubscribedQuality]) {
        let _parameters = parameters
        let encodings = _parameters.encodings

        var didUpdate = false

        // For SVC mode...
        if let firstEncoding = encodings.first,
           ScalabilityMode.fromString(firstEncoding.scalabilityMode) != nil
        {
            let _enabled = qualities.highest != .off
            if firstEncoding.isActive != _enabled {
                firstEncoding.isActive = _enabled
                didUpdate = true
            }
        } else {
            // For Simulcast...
            for e in qualities {
                guard let rid = e.quality.asRID else { continue }
                guard let encodingforRID = encodings.first(where: { $0.rid == rid }) else { continue }

                if encodingforRID.isActive != e.enabled {
                    didUpdate = true
                    encodingforRID.isActive = e.enabled
                    log("Setting layer \(e.quality) to \(e.enabled)", .info)
                }
            }

            // Non simulcast streams don't have RIDs, handle here.
            if encodings.count == 1, qualities.count >= 1 {
                let firstEncoding = encodings.first!
                let firstQuality = qualities.first!

                if firstEncoding.isActive != firstQuality.enabled {
                    didUpdate = true
                    firstEncoding.isActive = firstQuality.enabled
                    log("Setting layer \(firstQuality.quality) to \(firstQuality.enabled)", .info)
                }
            }
        }

        if didUpdate {
            parameters = _parameters
        }
    }
}
