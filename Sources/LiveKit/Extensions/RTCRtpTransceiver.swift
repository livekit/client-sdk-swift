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

internal import LiveKitWebRTC

extension LKRTCRtpTransceiver: Loggable {
    /// Attempts to set preferred video codec.
    func set(preferredVideoCodec codec: VideoCodec, exceptCodec: VideoCodec? = nil) {
        // Get list of supported codecs...
        let allVideoCodecs = RTC.videoSenderCapabilities.codecs

        // Get the RTCRtpCodecCapability of the preferred codec
        let preferredCodecCapability = allVideoCodecs.first { $0.name.lowercased() == codec.name }

        // Get list of capabilities other than the preferred one
        let otherCapabilities = allVideoCodecs.filter {
            $0.name.lowercased() != codec.name && $0.name.lowercased() != exceptCodec?.name
        }

        // Bring preferredCodecCapability to the front and combine all capabilities
        let combinedCapabilities = [preferredCodecCapability] + otherCapabilities

        // Codecs not set in codecPreferences will not be negotiated in the offer
        codecPreferences = combinedCapabilities.compactMap { $0 }

        log("codecPreferences set: \(codecPreferences.map { String(describing: $0) }.joined(separator: ", "))")

        if codecPreferences.first?.name.lowercased() != codec.name {
            log("Preferred codec is not first of codecPreferences", .error)
        }
    }
}
