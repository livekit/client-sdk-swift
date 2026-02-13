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

public let defaultRatchetSalt: String = "LKFrameEncryptionKey"
public let defaultMagicBytes: String = "LK-ROCKS"
// Disable automatic ratcheting for the default shared key mode
public let defaultRatchetWindowSize: Int32 = 0
public let defaultFailureTolerance: Int32 = -1
public let defaultKeyRingSize: Int32 = 16

@objcMembers
public final class KeyProviderOptions: NSObject, Sendable {
    public let sharedKey: Bool

    public let ratchetSalt: Data

    public let ratchetWindowSize: Int32

    public let uncryptedMagicBytes: Data

    public let failureTolerance: Int32

    public let keyRingSize: Int32

    public init(sharedKey: Bool = true,
                ratchetSalt: Data = defaultRatchetSalt.data(using: .utf8)!,
                ratchetWindowSize: Int32 = defaultRatchetWindowSize,
                uncryptedMagicBytes: Data = defaultMagicBytes.data(using: .utf8)!,
                failureTolerance: Int32 = defaultFailureTolerance,
                keyRingSize: Int32 = defaultKeyRingSize)
    {
        self.sharedKey = sharedKey
        self.ratchetSalt = ratchetSalt
        self.ratchetWindowSize = ratchetWindowSize
        self.uncryptedMagicBytes = uncryptedMagicBytes
        self.failureTolerance = failureTolerance
        self.keyRingSize = keyRingSize
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return sharedKey == other.sharedKey &&
            ratchetSalt == other.ratchetSalt &&
            ratchetWindowSize == other.ratchetWindowSize &&
            uncryptedMagicBytes == other.uncryptedMagicBytes &&
            failureTolerance == other.failureTolerance &&
            keyRingSize == other.keyRingSize
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(sharedKey)
        hasher.combine(ratchetSalt)
        hasher.combine(ratchetWindowSize)
        hasher.combine(uncryptedMagicBytes)
        hasher.combine(failureTolerance)
        hasher.combine(keyRingSize)
        return hasher.finalize()
    }
}

@objcMembers
public final class BaseKeyProvider: NSObject, Loggable, Sendable {
    public let options: KeyProviderOptions

    // MARK: - Internal

    let rtcKeyProvider: LKRTCFrameCryptorKeyProvider

    // MARK: - State

    struct State {
        var currentKeyIndex: Int32 = 0
    }

    private let _state = StateSync(State())

    // MARK: Init

    public init(isSharedKey: Bool, sharedKey: String? = nil) {
        options = KeyProviderOptions(sharedKey: isSharedKey)
        rtcKeyProvider = LKRTCFrameCryptorKeyProvider(ratchetSalt: options.ratchetSalt,
                                                      ratchetWindowSize: options.ratchetWindowSize,
                                                      sharedKeyMode: isSharedKey,
                                                      uncryptedMagicBytes: options.uncryptedMagicBytes,
                                                      failureTolerance: options.failureTolerance,
                                                      keyRingSize: options.keyRingSize)
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
                                                      uncryptedMagicBytes: options.uncryptedMagicBytes,
                                                      failureTolerance: options.failureTolerance,
                                                      keyRingSize: options.keyRingSize)
    }

    // MARK: - Key management

    public func setKey(key: String, participantId: String? = nil, index: Int32? = nil) {
        let targetIndex = index ?? getCurrentKeyIndex()

        if options.sharedKey {
            let keyData = key.data(using: .utf8)!
            rtcKeyProvider.setSharedKey(keyData, with: targetIndex)
        } else {
            if participantId == nil {
                log("setKey: Please provide valid participantId for non-SharedKey mode.")
                return
            }

            let keyData = key.data(using: .utf8)!
            rtcKeyProvider.setKey(keyData, with: targetIndex, forParticipant: participantId!)
        }

        setCurrentKeyIndex(targetIndex)
    }

    public func ratchetKey(participantId: String? = nil, index: Int32? = nil) -> Data? {
        let targetIndex = index ?? getCurrentKeyIndex()

        if options.sharedKey {
            return rtcKeyProvider.ratchetSharedKey(targetIndex)
        }

        if participantId == nil {
            log("ratchetKey: Please provide valid participantId for non-SharedKey mode.")
            return nil
        }

        return rtcKeyProvider.ratchetKey(participantId!, with: targetIndex)
    }

    public func exportKey(participantId: String? = nil, index: Int32? = nil) -> Data? {
        let targetIndex = index ?? getCurrentKeyIndex()

        if options.sharedKey {
            return rtcKeyProvider.exportSharedKey(targetIndex)
        }

        if participantId == nil {
            log("exportKey: Please provide valid participantId for non-SharedKey mode.")
            return nil
        }

        return rtcKeyProvider.exportKey(participantId!, with: targetIndex)
    }

    public func setSifTrailer(trailer: Data) {
        rtcKeyProvider.setSifTrailer(trailer)
    }

    public func getCurrentKeyIndex() -> Int32 {
        _state.currentKeyIndex
    }

    public func setCurrentKeyIndex(_ index: Int32) {
        _state.mutate { $0.currentKeyIndex = index % options.keyRingSize }
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
