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
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
import LiveKitWebRTC

/// Records every frame-cryptor state a room reports.
private final class E2EEStateWatcher: RoomDelegate, @unchecked Sendable {
    private let _states = StateSync([E2EEState]())
    private let _onState = StateSync<(@Sendable (E2EEState) -> Void)?>(nil)

    var states: [E2EEState] { _states.copy() }

    func onState(_ block: @escaping @Sendable (E2EEState) -> Void) {
        _onState.mutate { $0 = block }
    }

    func room(_: Room, trackPublication _: TrackPublication, didUpdateE2EEState state: E2EEState) {
        _states.mutate { $0.append(state) }
        _onState.copy()?(state)
    }

    /// Waits until the most recently reported state is `state`.
    func waitFor(_ state: E2EEState, timeout: TimeInterval = 30) async throws {
        try await waitUntil(timeout: timeout, "state \(state.toString()), saw \(describe(states))") { states.last == state }
    }
}

private func describe(_ states: [E2EEState]) -> [String] {
    states.map { $0.toString() }
}

private func waitUntil(timeout: TimeInterval = 30, _ what: @autoclosure () -> String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 200_000_000)
    }
    throw LiveKitError(.timedOut, message: "Timed out waiting for \(what())")
}

/// Serialized: each case joins its own room pair on the one local dev server, and the server reports
/// spurious connect timeouts when several pairs negotiate at once.
@Suite(.serialized, .tags(.e2e, .e2ee, .media), TestLimits.e2e)
struct FrameCryptorKeyIndexTests {
    private struct Peers {
        let publisherKeys: BaseKeyProvider
        let subscriberKeys: BaseKeyProvider
        let publisher = E2EEStateWatcher()
        let subscriber = E2EEStateWatcher()

        init(options: KeyProviderOptions) {
            publisherKeys = BaseKeyProvider(options: options)
            subscriberKeys = BaseKeyProvider(options: options)
        }

        var rooms: [RoomTestingOptions] {
            [
                RoomTestingOptions(delegate: publisher, encryptionOptions: EncryptionOptions(keyProvider: publisherKeys), canPublish: true),
                RoomTestingOptions(delegate: subscriber, encryptionOptions: EncryptionOptions(keyProvider: subscriberKeys), canSubscribe: true),
            ]
        }
    }

    private static let keyRingSize: Int32 = 16
    private static let dimensions: Dimensions = .h720_169

    /// Publishes a buffer-captured video track fed with blank frames; a headless `TestAudioTrack`
    /// captures nothing, so no encoded frame of its ever reaches a cryptor.
    private static func publishVideo(in room: Room) async throws -> AnyTaskCancellable {
        let track = await LocalVideoTrack.createBufferTrack(name: "camera",
                                                            source: .camera,
                                                            options: BufferCaptureOptions(dimensions: dimensions))
        let capturer = try #require(track.capturer as? BufferCapturer)
        let feeder = capturer.startFeedingFrames(dimensions: dimensions).cancellable()
        _ = try await room.localParticipant.publish(videoTrack: track)
        return feeder
    }

    /// A key installed only at a non-zero ring index must be the one the publisher's cryptor
    /// stamps: before provider-driven stamping every sender wrote kid 0, the publisher reported
    /// `.missing_key` for its own track, and no frame ever reached the subscriber.
    @Test(arguments: [Int32(1), 15], [KeyDerivationAlgorithm.pbkdf2, .hkdf])
    func senderStampsProviderKeyIndex(index: Int32, algorithm: KeyDerivationAlgorithm) async throws {
        let peers = Peers(options: KeyProviderOptions(sharedKey: true, keyRingSize: Self.keyRingSize, keyDerivationAlgorithm: algorithm))
        peers.publisherKeys.setKey(key: "k1", index: index)
        peers.subscriberKeys.setKey(key: "k1", index: index)

        try await confirmation("subscriber decrypts with the key at index \(index)") { decrypted in
            peers.subscriber.onState { if $0 == .ok { decrypted() } }

            try await TestEnvironment.withRooms(peers.rooms) { rooms in
                let feeder = try await Self.publishVideo(in: #require(rooms.first))
                defer { feeder.cancel() }
                // A publisher that cannot find its own key reports it at once; do not wait out the
                // subscriber's budget for frames that were never sent.
                try await waitUntil("subscriber .ok, saw \(describe(peers.subscriber.states)), publisher saw \(describe(peers.publisher.states))") {
                    peers.subscriber.states.last == .ok || peers.publisher.states.contains(.missing_key)
                }
            }

            #expect(peers.subscriber.states.last == .ok, "subscriber states: \(describe(peers.subscriber.states))")
            #expect(!peers.publisher.states.contains(.missing_key), "publisher states: \(describe(peers.publisher.states))")
        }
    }

    /// Rotating the publisher's key to another ring index re-stamps its live sender cryptor: the
    /// subscriber, which still holds nothing at the new index, reports `.missing_key`, then whatever
    /// it installs there decides the outcome. `failureTolerance: 0` because the default (-1) never
    /// reports `.decryption_failed`.
    @Test(arguments: [
        ("k2", E2EEState.ok),
        ("not-k2", E2EEState.decryption_failed),
    ])
    func rotationFollowsProviderKeyIndex(subscriberKey: String, expected: E2EEState) async throws {
        let peers = Peers(options: KeyProviderOptions(sharedKey: true, failureTolerance: 0, keyRingSize: Self.keyRingSize))
        peers.publisherKeys.setKey(key: "k1", index: 1)
        peers.subscriberKeys.setKey(key: "k1", index: 1)

        try await TestEnvironment.withRooms(peers.rooms) { rooms in
            let feeder = try await Self.publishVideo(in: #require(rooms.first))
            defer { feeder.cancel() }
            try await peers.subscriber.waitFor(.ok)

            peers.publisherKeys.setKey(key: "k2", index: 0)
            try await peers.subscriber.waitFor(.missing_key)

            peers.subscriberKeys.setKey(key: subscriberKey, index: 0)
            try await peers.subscriber.waitFor(expected)
        }

        #expect(peers.publisherKeys.getCurrentKeyIndex() == 0)
        #expect(!peers.publisher.states.contains(.missing_key), "publisher states: \(describe(peers.publisher.states))")
    }
}

@Suite(.tags(.e2ee))
struct KeyIndexObserverTests {
    private static let keyRingSize: Int32 = 16
    private static let room = Room()

    private static func provider(sharedKey: Bool = true) -> BaseKeyProvider {
        BaseKeyProvider(options: KeyProviderOptions(sharedKey: sharedKey, keyRingSize: keyRingSize))
    }

    /// Returns the indices an observer registered for the duration of `body` was notified of.
    private static func observed(_ provider: BaseKeyProvider, _ body: (BaseKeyProvider) -> Void) -> [Int32] {
        let received = StateSync([Int32]())
        let owner = NSObject()
        provider.addKeyIndexObserver(owner) { index, _ in received.mutate { $0.append(index) } }
        body(provider)
        provider.removeKeyIndexObserver(owner)
        return received.copy()
    }

    @Test(arguments: [Int32(0), 5, 21])
    func setKeyNotifiesModuloIndex(index: Int32) {
        let provider = Self.provider()
        #expect(Self.observed(provider) { $0.setKey(key: "k", index: index) } == [index % Self.keyRingSize])
    }

    @Test(arguments: [Int32(0), 5, 21])
    func setCurrentKeyIndexNotifiesModuloIndex(index: Int32) {
        let provider = Self.provider()
        #expect(Self.observed(provider) { $0.setCurrentKeyIndex(index) } == [index % Self.keyRingSize])
    }

    @Test
    func perParticipantSetKeyDoesNotMoveIndex() {
        let provider = Self.provider(sharedKey: false)
        let fired = Self.observed(provider) {
            $0.setKey(key: "k", participantId: "remote", index: 3)
            $0.setKey(key: "k", participantId: "local", index: 5)
        }
        #expect(fired.isEmpty)
        #expect(provider.getCurrentKeyIndex() == 0)

        #expect(Self.observed(provider) { $0.setCurrentKeyIndex(5) } == [5])
        #expect(provider.getCurrentKeyIndex() == 5)
    }

    @Test
    func removedObserverIsNotNotified() {
        let provider = Self.provider()
        let received = StateSync([Int32]())
        let owner = NSObject()
        provider.addKeyIndexObserver(owner) { index, _ in received.mutate { $0.append(index) } }
        provider.removeKeyIndexObserver(owner)
        provider.setCurrentKeyIndex(2)
        #expect(received.copy().isEmpty)
    }

    @Test
    func managerIsNotRetainedByProvider() {
        let provider = Self.provider()
        weak var manager: E2EEManager?
        do {
            let strong = E2EEManager(options: EncryptionOptions(keyProvider: provider))
            manager = strong
            #expect(manager != nil)
        }
        #expect(manager == nil)
        provider.setCurrentKeyIndex(1)
    }

    @Test
    func generationsAreMonotonicPerChange() {
        let provider = Self.provider()
        let received = StateSync([UInt64]())
        let owner = NSObject()
        provider.addKeyIndexObserver(owner) { _, generation in received.mutate { $0.append(generation) } }
        provider.setCurrentKeyIndex(1)
        provider.setKey(key: "k", index: 2)
        provider.removeKeyIndexObserver(owner)
        #expect(received.copy() == [1, 2])
        #expect(provider.currentKeyIndexWithGeneration() == (2, 2))
    }

    /// Observer delivery happens outside the provider's lock, so two rotations can reach the
    /// manager in the wrong order; the generation decides, not the arrival order.
    ///
    /// The WebRTC objects are created and read on the RTC executor and their final releases go to
    /// the separate `RTC.park` queue: every call on them and the last release block on a WebRTC
    /// thread, which must not happen on the cooperative pool.
    @Test
    func olderGenerationDoesNotOverrideNewerIndex() async throws {
        let provider = Self.provider()
        let manager = E2EEManager(options: EncryptionOptions(keyProvider: provider))
        let publication = LocalTrackPublication(info: Livekit_TrackInfo.with { $0.sid = "TR_sender" },
                                                participant: Self.room.localParticipant)
        provider.setCurrentKeyIndex(4)

        try await RTC.run {
            let pc = try #require(RTC.peerConnectionFactory.peerConnection(with: .liveKitDefault(),
                                                                           constraints: .defaultPCConstraints,
                                                                           delegate: nil))
            var created: [AnyObject] = []
            defer {
                manager.cleanUp()
                nonisolated(unsafe) let pc = pc
                nonisolated(unsafe) let objects = created
                RTC.park {
                    pc.close()
                    _ = objects
                }
            }
            let track = RTC.createAudioTrack(source: RTC.createAudioSource(nil))
            created.append(track)
            let sender = try #require(pc.add(track, streamIds: ["local"]))
            created.append(sender)
            let frameCryptor = try #require(LKRTCFrameCryptor(factory: RTC.peerConnectionFactory,
                                                              rtpSender: sender,
                                                              participantId: "local",
                                                              algorithm: .aesGcm,
                                                              keyProvider: provider.rtcKeyProvider))
            created.append(frameCryptor)

            manager.install(frameCryptor: frameCryptor, for: publication, participantIdentity: Participant.Identity(from: "local"))
            #expect(frameCryptor.keyIndex == 4)

            manager.setSenderKeyIndex(0, generation: 1)
            #expect(frameCryptor.keyIndex == 4, "the generation read at creation must not be re-applied")

            manager.setSenderKeyIndex(2, generation: 3)
            manager.setSenderKeyIndex(1, generation: 2)
            #expect(frameCryptor.keyIndex == 2)

            manager.setSenderKeyIndex(3, generation: 4)
            #expect(frameCryptor.keyIndex == 3)
        }
    }

    /// One provider shared by several managers keeps one observer per manager, and a manager
    /// going away leaves the others registered.
    @Test
    func sharedProviderKeepsRemainingManagersObserving() {
        let provider = Self.provider()
        #expect(provider.keyIndexObserverCount == 0)

        let survivor = E2EEManager(options: EncryptionOptions(keyProvider: provider))
        do {
            let transient = E2EEManager(options: EncryptionOptions(keyProvider: provider))
            #expect(provider.keyIndexObserverCount == 2)
            withExtendedLifetime(transient) {}
        }
        #expect(provider.keyIndexObserverCount == 1)

        provider.setCurrentKeyIndex(3)
        #expect(provider.getCurrentKeyIndex() == 3)
        withExtendedLifetime(survivor) {}
    }
}
