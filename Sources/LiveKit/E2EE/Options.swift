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

@objc
public enum EncryptionType: Int, Sendable {
    case none
    case gcm
    case custom
}

extension EncryptionType {
    func toPBType() -> Livekit_Encryption.TypeEnum {
        switch self {
        case .none: .none
        case .gcm: .gcm
        case .custom: .custom
        default: .custom
        }
    }
}

extension Livekit_Encryption.TypeEnum {
    func toLKType() -> EncryptionType {
        switch self {
        case .none: .none
        case .gcm: .gcm
        case .custom: .custom
        default: .custom
        }
    }
}

@objc
public final class E2EEOptions: NSObject, Sendable {
    @objc
    public let keyProvider: BaseKeyProvider

    @objc
    public let encryptionType: EncryptionType

    public init(keyProvider: BaseKeyProvider,
                encryptionType: EncryptionType = .gcm)
    {
        self.keyProvider = keyProvider
        self.encryptionType = encryptionType
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return keyProvider == other.keyProvider &&
            encryptionType == other.encryptionType
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(keyProvider)
        hasher.combine(encryptionType)
        return hasher.finalize()
    }
}
