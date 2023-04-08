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
        guard let codecName = codec.rawStringValue else { return }

        let capabilities = Engine.videoSenderCapabilities

        log("videoSenderCapabilities: \(capabilities.codecs.map({ String(describing: $0) }).joined(separator: ", "))")

        codecPreferences = [
            capabilities.codecs.first(where: { $0.name.lowercased() == codecName.lowercased() })
        ].compactMap { $0 }
    }
}
