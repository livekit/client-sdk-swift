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

internal import LiveKitWebRTC
import Foundation

extension LKRTCRtpTransceiver: Loggable {
    /// Attempts to set preferred video codec.
    @RTC
    func set(preferredVideoCodec codec: VideoCodec, exceptCodec: VideoCodec? = nil) throws {
        // Get list of supported codecs...
        let allVideoCodecs = RTC.videoSenderCapabilities.codecs

        // Keep every capability whose codec name matches the preferred codec (H264 exposes
        // multiple profile-level-id entries; offering only one breaks server-side negotiation).
        let preferredCapabilities = allVideoCodecs.filter { $0.name.lowercased() == codec.name }

        // Get list of capabilities other than the preferred one
        let otherCapabilities = allVideoCodecs.filter {
            $0.name.lowercased() != codec.name && $0.name.lowercased() != exceptCodec?.name
        }

        // Bring preferred capabilities to the front and combine
        let combinedCapabilities = preferredCapabilities + otherCapabilities

        // Codecs not set in codecPreferences will not be negotiated in the offer
        do {
            try setCodecPreferences(combinedCapabilities, error: ())
        } catch {
            throw LiveKitError(.webRTC, message: "Failed to set codec preferences", internalError: error)
        }

        log("codecPreferences set: \(codecPreferences.map { String(describing: $0) }.joined(separator: ", "))")

        if codecPreferences.first?.name.lowercased() != codec.name {
            log("Preferred codec is not first of codecPreferences", .error)
        }
    }

    /// Stops offering FlexFEC on this transceiver, keeping the order of any codec preferences set.
    ///
    /// For simulcast senders only: WebRTC allocates them no FlexFEC SSRC, and when FlexFEC is
    /// negotiated anyway its send statistics read a protected media SSRC that does not exist and
    /// abort the process. Does nothing when FlexFEC is not offered.
    @RTC
    func removeFlexFEC() throws {
        let current = codecPreferences.isEmpty ? RTC.videoSenderCapabilities.codecs : codecPreferences
        let withoutFlexFEC = current.filter { $0.name.lowercased() != Self.flexFECCodecName }
        guard withoutFlexFEC.count != current.count else { return }

        do {
            try setCodecPreferences(withoutFlexFEC, error: ())
        } catch {
            throw LiveKitError(.webRTC, message: "Failed to remove FlexFEC from codec preferences", internalError: error)
        }

        log("Removed FlexFEC from codecPreferences of a simulcast sender")
    }

    private static let flexFECCodecName = "flexfec-03"
}
