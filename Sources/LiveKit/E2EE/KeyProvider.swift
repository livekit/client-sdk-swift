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

public let defaultRatchetSalt: String = "LKFrameEncryptionKey"
public let defaultMagicBytes: String = "LK-ROCKS"
public let defaultRatchetWindowSize: Int32 = 0
public let defaultFailureTolerance: Int32 = -1

@objc
public final class KeyProviderOptions: NSObject, Sendable {
    @objc
    public let sharedKey: Bool

    @objc
    public let ratchetSalt: Data

    @objc
    public let ratchetWindowSize: Int32

    @objc
    public let uncryptedMagicBytes: Data

    @objc
    public let failureTolerance: Int32

    public init(sharedKey: Bool = true,
                ratchetSalt: Data = defaultRatchetSalt.data(using: .utf8)!,
                ratchetWindowSize: Int32 = defaultRatchetWindowSize,
                uncryptedMagicBytes: Data = defaultMagicBytes.data(using: .utf8)!,
                failureTolerance: Int32 = defaultFailureTolerance)
    {
        self.sharedKey = sharedKey
        self.ratchetSalt = ratchetSalt
        self.ratchetWindowSize = ratchetWindowSize
        self.uncryptedMagicBytes = uncryptedMagicBytes
        self.failureTolerance = failureTolerance
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return sharedKey == other.sharedKey &&
            ratchetSalt == other.ratchetSalt &&
            ratchetWindowSize == other.ratchetWindowSize &&
            uncryptedMagicBytes == other.uncryptedMagicBytes &&
            failureTolerance == other.failureTolerance
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(sharedKey)
        hasher.combine(ratchetSalt)
        hasher.combine(ratchetWindowSize)
        hasher.combine(uncryptedMagicBytes)
        hasher.combine(failureTolerance)
        return hasher.finalize()
    }
}

@objc
public final class BaseKeyProvider: NSObject, Loggable, Sendable {
    @objc
    public let options: KeyProviderOptions

    // MARK: - Internal

    let rtcKeyProvider: LKRTCFrameCryptorKeyProvider

    public init(isSharedKey: Bool, sharedKey: String? = nil) {
        options = KeyProviderOptions(sharedKey: isSharedKey)
        rtcKeyProvider = LKRTCFrameCryptorKeyProvider(ratchetSalt: options.ratchetSalt,
                                                      ratchetWindowSize: options.ratchetWindowSize,
                                                      sharedKeyMode: isSharedKey,
                                                      uncryptedMagicBytes: options.uncryptedMagicBytes,
                                                      failureTolerance: options.failureTolerance,
                                                      keyRingSize: 16)
        if isSharedKey, sharedKey != nil {
            let keyData = sharedKey!.data(using: .utf8)!
            rtcKeyProvider.setSharedKey(keyData, with: 0)
        }
    }

    public init(options: KeyProviderOptions = KeyProviderOptions()) {
        self.options = options
        rtcKeyProvider = LKRTCFrameCryptorKeyProvider(ratchetSalt: options.ratchetSalt,
                                                      ratchetWindowSize: options.ratchetWindowSize,
                                                      sharedKeyMode: options.sharedKey,
                                                      uncryptedMagicBytes: options.uncryptedMagicBytes)
    }

    public func setKey(key: String, participantId: String? = nil, index: Int32? = 0) {
        if options.sharedKey {
            let keyData = key.data(using: .utf8)!
            rtcKeyProvider.setSharedKey(keyData, with: index ?? 0)
            return
        }

        if participantId == nil {
            log("setKey: Please provide valid participantId for non-SharedKey mode.")
            return
        }

        let keyData = key.data(using: .utf8)!
        rtcKeyProvider.setKey(keyData, with: index!, forParticipant: participantId!)
    }

    public func ratchetKey(participantId: String? = nil, index: Int32? = 0) -> Data? {
        if options.sharedKey {
            return rtcKeyProvider.ratchetSharedKey(index ?? 0)
        }

        if participantId == nil {
            log("ratchetKey: Please provide valid participantId for non-SharedKey mode.")
            return nil
        }

        return rtcKeyProvider.ratchetKey(participantId!, with: index ?? 0)
    }

    public func exportKey(participantId: String? = nil, index: Int32? = 0) -> Data? {
        if options.sharedKey {
            return rtcKeyProvider.exportSharedKey(index ?? 0)
        }

        if participantId == nil {
            log("exportKey: Please provide valid participantId for non-SharedKey mode.")
            return nil
        }

        return rtcKeyProvider.exportKey(participantId!, with: index ?? 0)
    }

    public func setSifTrailer(trailer: Data) {
        rtcKeyProvider.setSifTrailer(trailer)
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return options == other.options &&
            rtcKeyProvider == other.rtcKeyProvider
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(options)
        hasher.combine(rtcKeyProvider)
        return hasher.finalize()
    }
}
