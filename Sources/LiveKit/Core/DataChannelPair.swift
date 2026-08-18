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

// MARK: - Internal delegate

protocol DataChannelDelegate: AnyObject, Sendable {
    func dataChannel(_ dataChannelPair: DataChannelPair, didReceiveDataPacket dataPacket: Livekit_DataPacket)
    func dataChannel(_ dataChannelPair: DataChannelPair, didFailToDecryptDataPacket dataPacket: Livekit_DataPacket, error: LiveKitError)
}

/// The lossy and reliable data channels for one peer connection, plus the packet semantics they
/// share: encryption, the receive-side dedup gate, and the pair-level open latch.
///
/// Each channel's queue, buffered-amount gate and per-kind policy belong to its own
/// ``DataChannelDrain``, which is also that channel's `LKRTCDataChannelDelegate` — so nothing here
/// dispatches on channel labels. What a drain cannot answer it hands back: received bytes, and
/// readiness changes that only matter to the pair.
///
/// ## Live readiness vs. the open latch
/// ``openCompleter`` is a *sticky latch* that resolves the first time **both** channels reach
/// `.open`, and stays resolved until ``reset(throwing:)``. `room.send(dataPacket:)` awaits it so a
/// never-connected transport fails in bounded time instead of hanging forever.
///
/// It is not a live gate. Each drain decides for itself, per send, whether its own channel can take
/// bytes — the two are independent SCTP streams, so a lossy blip must not stall reliable sends.
///
/// ## Concurrency model
/// `@unchecked Sendable`. `_state` holds the dedup table and the E2EE manager behind a lock; the
/// drains own everything else and synchronize themselves.
class DataChannelPair: NSObject, @unchecked Sendable, Loggable {
    // MARK: - Public

    let delegates = MulticastDelegate<DataChannelDelegate>(label: "DataChannelDelegate")

    let openCompleter = AsyncCompleter<Void>(label: "Data channel open", defaultTimeout: .defaultPublisherDataChannelOpen)

    /// Whether *both* channels can currently take bytes. Only the open latch and diagnostics use
    /// this; the send path gates per channel.
    var isOpen: Bool { lossy.isOpen && reliable.isOpen }

    // MARK: - Private

    private struct State {
        var reliableReceivedState: TTLDictionary<String, UInt32> = TTLDictionary(ttl: reliableReceivedStateTTL)
        var e2eeManager: E2EEManager?
    }

    private let _state = StateSync(State())

    // Implicitly unwrapped because their message and state callbacks capture `self`, which is not
    // available until after `super.init()`. Assigned there, never reassigned.
    private var lossy: DataChannelDrain<LossyStage>!
    private var reliable: DataChannelDrain<ReliableStage>!

    // MARK: - Init

    init(delegate: DataChannelDelegate? = nil,
         lossyChannel: LKRTCDataChannel? = nil,
         reliableChannel: LKRTCDataChannel? = nil)
    {
        super.init()

        if let delegate {
            delegates.add(delegate: delegate)
        }

        lossy = DataChannelDrain(
            label: LKRTCDataChannel.Labels.lossy,
            lowWaterMark: Self.lossyLowThreshold,
            overflow: .dropOldest,
            stage: LossyStage(),
            maxMessageSize: Self.defaultMaxMessageSize,
            onMessage: { [weak self] data in self?.handle(received: data, isReliable: false) },
            onStateChange: { [weak self] _ in self?.handleStateChange() },
        )
        reliable = DataChannelDrain(
            label: LKRTCDataChannel.Labels.reliable,
            lowWaterMark: Self.reliableLowThreshold,
            overflow: .park,
            stage: ReliableStage(retryFloor: Self.reliableRetryAmount),
            maxMessageSize: Self.defaultMaxMessageSize,
            onMessage: { [weak self] data in self?.handle(received: data, isReliable: true) },
            onStateChange: { [weak self] _ in self?.handleStateChange() },
        )

        if let lossyChannel { set(lossy: lossyChannel) }
        if let reliableChannel { set(reliable: reliableChannel) }
    }

    // MARK: - Channels

    func set(reliable channel: LKRTCDataChannel?) {
        reliable.setChannel(channel)
        handleStateChange()
    }

    func set(lossy channel: LKRTCDataChannel?) {
        lossy.setChannel(channel)
        handleStateChange()
    }

    /// Resolves the open latch once both channels are usable. Reached from either drain's state
    /// callback and from a channel swap.
    private func handleStateChange() {
        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    /// Update the negotiated SCTP max-message-size cap on both channels. Called by the room after
    /// parsing `a=max-message-size` from the publisher answer SDP. `0` is honored as "no limit".
    func set(maxMessageSize: UInt64) {
        lossy.maxMessageSize = maxMessageSize
        reliable.maxMessageSize = maxMessageSize
    }

    func set(e2eeManager: E2EEManager?) {
        _state.mutate { $0.e2eeManager = e2eeManager }
    }

    func reset(throwing error: Error? = nil) {
        _state.mutate { $0.reliableReceivedState.removeAll() }
        lossy.reset(throwing: error)
        reliable.reset(throwing: error)
        openCompleter.reset(throwing: error)
    }

    // MARK: - Send

    func send(userPacket: Livekit_UserPacket, kind: Livekit_DataPacket_Kind) async throws {
        try await send(dataPacket: .with {
            $0.kind = kind // TODO: field is deprecated
            $0.user = userPacket
        })
    }

    func send(dataPacket packet: consuming Livekit_DataPacket) async throws {
        // Encrypt off the event loop: CPU work that doesn't touch ordering.
        let encryptedPacket = try withEncryption(packet)
        let isLossy = encryptedPacket.kind == .lossy // TODO: field is deprecated

        try await withCheckedThrowingContinuation { continuation in
            // Serialization and sequence assignment happen inside the drain, so the sequence on the
            // wire matches the FIFO order in which writes reach `sendData`.
            if isLossy {
                lossy.submit(encryptedPacket, continuation: continuation)
            } else {
                reliable.submit(encryptedPacket, continuation: continuation)
            }
        }
    }

    private func withEncryption(_ packet: Livekit_DataPacket) throws -> Livekit_DataPacket {
        guard let e2eeManager = _state.e2eeManager, e2eeManager.isDataChannelEncryptionEnabled,
              let payload = Livekit_EncryptedPacketPayload(dataPacket: packet) else { return packet }
        let encrypted: Livekit_EncryptedPacket
        do {
            let payloadData = try payload.serializedData()
            encrypted = try Livekit_EncryptedPacket(rtcPacket: e2eeManager.encrypt(data: payloadData))
        } catch {
            throw LiveKitError(.encryptionFailed, internalError: error)
        }
        return packet.modifying { $0.encryptedPacket = encrypted }
    }

    func retryReliable(lastSequence: UInt32) {
        reliable.submit(command: .replay(after: lastSequence))
    }

    // MARK: - Receive

    private func handle(received data: Data, isReliable: Bool) {
        guard let dataPacket = try? Livekit_DataPacket(serializedBytes: data) else {
            log("Could not decode data message", .error)
            return
        }

        if isReliable, dataPacket.sequence > 0, !dataPacket.participantSid.isEmpty {
            // Check and update in one locked step so two concurrent receives for the same sender
            // can't both pass the dedup gate.
            let isDuplicate = _state.mutate { state -> Bool in
                if let lastSeq = state.reliableReceivedState[dataPacket.participantSid], dataPacket.sequence <= lastSeq {
                    return true
                }
                state.reliableReceivedState[dataPacket.participantSid] = dataPacket.sequence
                return false
            }
            if isDuplicate {
                log("Ignoring duplicate/out-of-order reliable data message", .warning)
                return
            }
        }

        guard let encryptedPacket = dataPacket.encryptedPacketOrNil,
              let e2eeManager = _state.e2eeManager
        else {
            delegates.notify {
                $0.dataChannel(self, didReceiveDataPacket: dataPacket)
            }
            return
        }

        do {
            let decryptedData = try e2eeManager.handle(encryptedData: encryptedPacket.toRTCEncryptedPacket(), participantIdentity: dataPacket.participantIdentity)
            let decryptedPayload = try Livekit_EncryptedPacketPayload(serializedBytes: decryptedData)

            let decrypted = dataPacket.modifying { decryptedPayload.applyTo(&$0) }

            delegates.notify { [decrypted] in
                $0.dataChannel(self, didReceiveDataPacket: decrypted)
            }
        } catch {
            log("Failed to decrypt data packet: \(error)", .error)
            delegates.notify {
                $0.dataChannel(self, didFailToDecryptDataPacket: dataPacket, error: LiveKitError(.decryptionFailed, internalError: error))
            }
        }
    }

    // MARK: - Sync state

    func infos() -> [Livekit_DataChannelInfo] {
        [lossy.info(), reliable.info()].compactMap(\.self)
    }

    func receiveStates() -> [Livekit_DataChannelReceiveState] {
        _state.read { state in
            state.reliableReceivedState.map { sid, seq in
                Livekit_DataChannelReceiveState.with {
                    $0.publisherSid = sid
                    $0.lastSeq = seq
                }
            }
        }
    }

    // MARK: - Constants

    private static let reliableLowThreshold: UInt64 = 2 * 1024 * 1024 // 2 MB

    /// The lossy channel drops rather than queues, so this bounds send latency rather than memory.
    /// client-sdk-js keeps its lossy threshold between 8 KiB and 256 KiB, tuned to roughly 100 ms of
    /// measured throughput; 256 KiB is that ceiling, where the 2 MB reliable figure would be eight
    /// times it.
    private static let lossyLowThreshold: UInt64 = 256 * 1024

    // If rtc drains its buffer to 0, keep at least this amount of data for retry.
    // Should be >= the full backpressure amount to avoid losing packets.
    private static let reliableRetryAmount: UInt64 = .init(Double(reliableLowThreshold) * 1.25)
    private static let reliableReceivedStateTTL: TimeInterval = 30

    /// Default max-message-size assumed before SDP negotiation completes, and
    /// the upper bound clamp applied to any value parsed from the SDP answer.
    /// LiveKit/pion advertises ~64 KiB; libwebrtc's internal default is 256 KiB.
    static let defaultMaxMessageSize: UInt64 = 64000
}

// MARK: - SDP parsing

/// Parses the `a=max-message-size` attribute (RFC 8841) from an SDP string,
/// returning the value in bytes. Returns `nil` when the attribute is absent
/// or malformed.
///
/// Per RFC 8841, a value of `0` indicates "no limit"; callers downstream
/// honor that by skipping the send-side size check.
func parseSDPMaxMessageSize(_ sdp: String) -> UInt64? {
    // `components(separatedBy: .newlines)` splits on Unicode scalars, which is
    // what we want here — `String.split` treats CRLF as a single grapheme and
    // would leave a stray `\r` on every line of a typical SDP.
    for line in sdp.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = "a=max-message-size:"
        guard trimmed.hasPrefix(prefix) else { continue }
        let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return UInt64(value)
    }
    return nil
}
