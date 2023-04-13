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
import Promises

extension RTCRtpTransceiver: Loggable {

    internal func setPreferredVideoCodec(_ codec: VideoCodec) {
        // set a single codec preference
        guard let codecName = codec.rawStringValue?.lowercased() else { return }

        let allVideoCodecs = Engine.videoSenderCapabilities.codecs

        log("videoSenderCapabilities: \(allVideoCodecs.map({ String(describing: $0) }).joined(separator: ", "))")

        // get the RTCRtpCodecCapability of the preferred codec
        let preferredCodecCapability = allVideoCodecs.first { $0.name.lowercased() == codecName }

        // get list of capabilities other than the preferred one
        let otherCapabilities = allVideoCodecs.filter { $0.name.lowercased() != codecName }

        // bring preferredCodecCapability to the front and combine all capabilities
        let combinedCapabilities = [preferredCodecCapability] + otherCapabilities

        // codecs not set in codecPreferences will not be negotiated in the offer
        codecPreferences = combinedCapabilities.compactMap { $0 }
    }
}
