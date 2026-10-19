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

/// Algorithm used to derive encryption keys from the input key material.
///
/// - SeeAlso: ``KeyProviderOptions``
@objc
public enum KeyDerivationAlgorithm: Int, Sendable {
    /// PBKDF2 — matches the WebRTC default and prior SDK behavior.
    case pbkdf2 = 0
    /// HKDF — required for interop with peers that derive keys via HKDF.
    case hkdf = 1
}

@objcMembers
public final class KeyProviderOptions: NSObject, Sendable {
    public let sharedKey: Bool

    public let ratchetSalt: Data

    public let ratchetWindowSize: Int32

    public let uncryptedMagicBytes: Data

    public let failureTolerance: Int32

    public let keyRingSize: Int32

    public let discardFrameWhenCryptorNotReady: Bool

    public let keyDerivationAlgorithm: KeyDerivationAlgorithm

    public init(sharedKey: Bool = true,
                ratchetSalt: Data = defaultRatchetSalt.data(using: .utf8)!,
                ratchetWindowSize: Int32 = defaultRatchetWindowSize,
                uncryptedMagicBytes: Data = defaultMagicBytes.data(using: .utf8)!,
                failureTolerance: Int32 = defaultFailureTolerance,
                keyRingSize: Int32 = defaultKeyRingSize,
                discardFrameWhenCryptorNotReady: Bool = false,
                keyDerivationAlgorithm: KeyDerivationAlgorithm = .pbkdf2)
    {
        self.sharedKey = sharedKey
        self.ratchetSalt = ratchetSalt
        self.ratchetWindowSize = ratchetWindowSize
        self.uncryptedMagicBytes = uncryptedMagicBytes
        self.failureTolerance = failureTolerance
        self.keyRingSize = keyRingSize
        self.discardFrameWhenCryptorNotReady = discardFrameWhenCryptorNotReady
        self.keyDerivationAlgorithm = keyDerivationAlgorithm
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return sharedKey == other.sharedKey &&
            ratchetSalt == other.ratchetSalt &&
            ratchetWindowSize == other.ratchetWindowSize &&
            uncryptedMagicBytes == other.uncryptedMagicBytes &&
            failureTolerance == other.failureTolerance &&
            keyRingSize == other.keyRingSize &&
            discardFrameWhenCryptorNotReady == other.discardFrameWhenCryptorNotReady &&
            keyDerivationAlgorithm == other.keyDerivationAlgorithm
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(sharedKey)
        hasher.combine(ratchetSalt)
        hasher.combine(ratchetWindowSize)
        hasher.combine(uncryptedMagicBytes)
        hasher.combine(failureTolerance)
        hasher.combine(keyRingSize)
        hasher.combine(discardFrameWhenCryptorNotReady)
        hasher.combine(keyDerivationAlgorithm)
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
        var keyIndexGeneration: UInt64 = 0
        var keyIndexObservers = [ObjectIdentifier: @Sendable (Int32, UInt64) -> Void]()
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
                                                      keyRingSize: options.keyRingSize,
                                                      discardFrameWhenCryptorNotReady: options.discardFrameWhenCryptorNotReady,
                                                      keyDerivationAlgorithm: options.keyDerivationAlgorithm.toRTCType())
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
                                                      keyRingSize: options.keyRingSize,
                                                      discardFrameWhenCryptorNotReady: options.discardFrameWhenCryptorNotReady,
                                                      keyDerivationAlgorithm: options.keyDerivationAlgorithm.toRTCType())
    }

    // MARK: - Key management

    public func setKey(key: String, participantId: String? = nil, index: Int32? = nil) {
        setKey(keyData: Data(key.utf8), participantId: participantId, index: index)
    }

    /// Sets a raw binary key without any string conversion.
    ///
    /// In shared key mode installing a key also makes `index` the current key index. In non-shared
    /// key mode it does not, since the key may belong to a remote participant: switch the local
    /// participant's index with ``setCurrentKeyIndex(_:)``.
    ///
    /// - Parameters:
    ///   - keyData: The key bytes, stored as provided.
    ///   - participantId: Required in non-shared key mode; the call is a no-op when `nil`.
    ///   - index: The key index to set. Defaults to the current key index.
    public func setKey(keyData: Data, participantId: String? = nil, index: Int32? = nil) {
        let targetIndex = index ?? getCurrentKeyIndex()

        if options.sharedKey {
            rtcKeyProvider.setSharedKey(keyData, with: targetIndex)
            setCurrentKeyIndex(targetIndex)
            return
        }

        guard let participantId else {
            log("setKey: Please provide valid participantId for non-SharedKey mode.")
            return
        }

        rtcKeyProvider.setKey(keyData, with: targetIndex, forParticipant: participantId)
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

    /// The key index the local participant encrypts with: stamped into every outgoing media frame
    /// and data packet, and pushed to the live media senders when it changes.
    public func getCurrentKeyIndex() -> Int32 {
        _state.currentKeyIndex
    }

    /// Switches the local participant's encryption to the key at `index` (modulo the key ring size).
    ///
    /// Takes effect immediately for the media tracks already published and for every data packet
    /// sent afterwards. Receivers are unaffected: they read the index from each frame.
    public func setCurrentKeyIndex(_ index: Int32) {
        let (currentKeyIndex, generation, observers) = _state.mutate {
            $0.currentKeyIndex = index % options.keyRingSize
            $0.keyIndexGeneration += 1
            return ($0.currentKeyIndex, $0.keyIndexGeneration, Array($0.keyIndexObservers.values))
        }
        for observer in observers {
            observer(currentKeyIndex, generation)
        }
    }

    // MARK: - Internal

    /// The current key index with the generation of the change that set it. Observers are
    /// notified outside the lock, so the generation is what lets them order concurrent changes.
    func currentKeyIndexWithGeneration() -> (index: Int32, generation: UInt64) {
        _state.read { ($0.currentKeyIndex, $0.keyIndexGeneration) }
    }

    var keyIndexObserverCount: Int {
        _state.keyIndexObservers.count
    }

    func addKeyIndexObserver(_ owner: AnyObject, _ observer: @escaping @Sendable (Int32, UInt64) -> Void) {
        _state.mutate { $0.keyIndexObservers[ObjectIdentifier(owner)] = observer }
    }

    func removeKeyIndexObserver(_ owner: AnyObject) {
        _state.mutate { $0.keyIndexObservers[ObjectIdentifier(owner)] = nil }
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

extension KeyDerivationAlgorithm {
    func toRTCType() -> LKRTCKeyDerivationAlgorithm {
        switch self {
        case .pbkdf2: LKRTCKeyDerivationAlgorithm(rawValue: 0)!
        case .hkdf: LKRTCKeyDerivationAlgorithm(rawValue: 1)!
        }
    }
}
