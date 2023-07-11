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

let defaultRatchetSalt: String = "LKFrameEncryptionKey"
let defaultMagicBytes: String = "LK-ROCKS"
let defaultRatchetWindowSize: Int32 = 16;

public class BaseKeyProvider: Loggable {
    var rtcKeyProvider: RTCFrameCryptorKeyProvider?
    var isSharedKey: Bool = true
    var sharedKey: String?
    
    public init(isSharedKey: Bool, sharedKey: String? = nil) {
        self.rtcKeyProvider = RTCFrameCryptorKeyProvider(ratchetSalt: defaultRatchetSalt.data(using: .utf8)!, ratchetWindowSize: defaultRatchetWindowSize, sharedKeyMode: isSharedKey, uncryptedMagicBytes: defaultMagicBytes.data(using: .utf8)!)
        self.isSharedKey = isSharedKey
        self.sharedKey = sharedKey
    }

    public func setKey(key: String, participantId: String? = nil, index: Int32? = 0) {
        if isSharedKey {
            self.sharedKey = key
            return
        }

        if participantId == nil {
            self.log("Please provide valid participantId for non-SharedKey mode.")
            return
        }

        let keyData = key.data(using: .utf8)!
        rtcKeyProvider?.setKey(keyData, with: index!, forParticipant: participantId!)
    }
}
