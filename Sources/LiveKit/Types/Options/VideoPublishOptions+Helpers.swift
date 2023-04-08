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

internal extension VideoPublishOptions {

    var isBackupPublishingEnabled: Bool {
        preferredBackupCodec != .none
    }

    var computedScalabilityMode: ScalabilityMode? {
        // currently, if codec is AV1 we always use L3T3.
        preferredCodec == .av1 ? .L3T3 : nil
    }

    var shouldUseCodec: VideoCodec {
        if preferredCodec == .av1 && !Engine.canEncodeAV1 {
            return .none
        }
        return preferredCodec
    }

    var shouldUseSimulcast: Bool {
        if preferredCodec == .av1 {
            return false
        }
        return simulcast
    }

    var shouldUseBackupCodec: Bool {
        // both are not default values...
        preferredCodec != .none &&
            preferredBackupCodec != .none &&
            // and they are not the same codec
            preferredCodec.rawStringValue != preferredBackupCodec.rawStringValue
    }
}
