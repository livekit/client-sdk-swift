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

@objc
public enum EncryptionType: Int {
    case none
    case gcm
    case custom
}

extension EncryptionType {

    func toPBType() -> Livekit_Encryption.TypeEnum {
        switch self {
        case .none: return .none
        case .gcm: return .gcm
        case .custom: return .custom
        default: return .custom
        }
    }
}

extension Livekit_Encryption.TypeEnum {
    func toLKType() -> EncryptionType {
        switch self {
        case .none: return .none
        case .gcm: return .gcm
        case .custom: return .custom
        default: return .custom
        }
    }
}

public class E2EEOptions {
    var keyProvider: BaseKeyProvider
    var encryptionType: EncryptionType = .gcm
    public init(keyProvider: BaseKeyProvider) {
        self.keyProvider = keyProvider
    }
}
