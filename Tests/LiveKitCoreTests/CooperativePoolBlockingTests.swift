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

@testable import LiveKit
import LiveKitWebRTC
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// SDK calls that `BlockingCall` into a WebRTC thread must not run on a cooperative-pool thread:
/// the pool does not grow when a thread blocks, so `activeProcessorCount` stalled calls freeze
/// every Swift Concurrency task in the process.
///
/// Serialized because the pool, the RTC executor, and libwebrtc's signaling thread are process-wide.
@Suite(.tags(.concurrency), .serialized, .bug("https://github.com/livekit/client-sdk-swift/issues/1100"))
struct CooperativePoolBlockingTests {
    private final class StubTransportDelegate: TransportDelegate {
        func transport(_: Transport, didUpdateState _: LKRTCPeerConnectionState) {}
        func transport(_: Transport, didGenerateIceCandidate _: IceCandidate) {}
        func transport(_: Transport, didOpenDataChannel _: LKRTCDataChannel) {}
        func transport(_: Transport, didAddTrack _: RTCMediaTrack, rtpReceiver _: RTCReceiver, streamIds _: [String]) {}
        func transport(_: Transport, didRemoveTrackWithId _: String) {}
        func transportShouldNegotiate(_: Transport) {}
    }

    /// `Room.disconnect()` → `cleanUpRTC` → `Transport.close()` → `PeerConnection::Close`, which
    /// blocks on the signaling thread; `Transport` is `@RTC`-isolated.
    @Test func transportCloseKeepsTheCooperativePoolResponsive() async throws {
        let width = ProcessInfo.processInfo.activeProcessorCount + 2
        var created: [Transport] = []
        for _ in 0 ..< width {
            try await created.append(Transport(config: .liveKitDefault(), target: .publisher, primary: true, delegate: StubTransportDelegate()))
        }
        let transports = created
        let wedge = try await SignalingThreadWedge.engage()

        let outcome = await poolStaysResponsive(width: width, release: wedge.release) { index in
            await transports[index].close()
        }

        #expect(outcome.responsive, "cooperative pool was starved while transports were closing")
        #expect(outcome.finishedBeforeProbe == 0, "no close was still in flight; the probe proved nothing")
    }

    /// `Track.start()` → `enable()` → `set_enabled`, which blocks on the signaling thread; a
    /// non-isolated call site that hops through `RTC.run`.
    @Test func trackEnableKeepsTheCooperativePoolResponsive() async throws {
        let width = ProcessInfo.processInfo.activeProcessorCount + 2
        let tracks = (0 ..< width).map { _ in TestAudioTrack() }
        let wedge = try await SignalingThreadWedge.engage()

        let outcome = await poolStaysResponsive(width: width, release: wedge.release) { index in
            _ = try? await tracks[index].disable()
        }

        #expect(outcome.responsive, "cooperative pool was starved while tracks were being disabled")
        #expect(outcome.finishedBeforeProbe == 0, "no disable was still in flight; the probe proved nothing")
    }

    /// Dropping the last reference to a factory-created track runs the proxy destructor on the
    /// signaling thread; `Track.deinit` parks it on the RTC executor.
    @Test func trackReleaseKeepsTheCooperativePoolResponsive() async throws {
        final class Holder: @unchecked Sendable {
            var track: Track?
            init(_ track: Track) { self.track = track }
        }
        let width = ProcessInfo.processInfo.activeProcessorCount + 2
        let holders = (0 ..< width).map { _ in Holder(TestAudioTrack()) }
        let wedge = try await SignalingThreadWedge.engage()

        let outcome = await poolStaysResponsive(width: width, release: wedge.release) { index in
            holders[index].track = nil
        }

        #expect(outcome.responsive, "cooperative pool was starved by proxy destructors")
        // Unlike the tests above, the blocking part is parked: dropping the reference returns at once.
        #expect(outcome.finishedBeforeProbe == width, "a release ran inline instead of being parked")
    }

    /// Building a configuration — the first thing `Room.connect()` does — is a plain value-object
    /// init and must not serialize behind WebRTC teardown. Fails if a queue hop is reintroduced
    /// for value objects: the channel release parked below holds the signaling thread.
    @Test func configurationBuildsWithoutWaitingOnWebRTC() async throws {
        let wedge = try await SignalingThreadWedge.engage(afterCreatingDataChannel: true)
        // Dropping the last channel reference is the blocking part: the proxy destructor runs on
        // the signaling thread.
        parkChannelRelease(wedge.takeDataChannel(), closing: true)

        let outcome = await poolStaysResponsive(release: wedge.release) { _ in
            _ = LKRTCConfiguration.liveKitDefault()
        }

        #expect(outcome.responsive, "cooperative pool was starved while building configurations")
        #expect(outcome.finishedBeforeProbe > 0, "building a configuration waited on a WebRTC thread")
    }

    /// A parked release runs on the concurrent release queue, never on the serial RTC executor:
    /// a blocking destructor must not head-of-line every other hop. Routing releases through the
    /// executor wedged the SDK under the sanitizers on CI.
    @Test func parkedReleaseDoesNotBlockTheRTCExecutor() async throws {
        let wedge = try await SignalingThreadWedge.engage(afterCreatingDataChannel: true)
        parkChannelRelease(wedge.takeDataChannel(), closing: true)

        let hopped = DispatchSemaphore(value: 0)
        Task.detached {
            await RTC.run {}
            hopped.signal()
        }

        let reachedExecutor = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let reached = hopped.wait(timeout: .now() + .seconds(2)) == .success
                wedge.release()
                continuation.resume(returning: reached)
            }
        }

        #expect(reachedExecutor, "a parked release head-of-lined the RTC executor")
    }

    /// The RTC executor has to answer the runtime's isolation check. Without the
    /// `SerialExecutor.checkIsolated` override the stdlib default traps unconditionally on
    /// iOS 18 / macOS 15-era runtimes, which crash-looped every test on Xcode 16.4 CI.
    ///
    /// - Note: A regression traps here rather than failing, but it names the culprit instead of
    ///   taking the whole suite down anonymously.
    @available(macOS 14.0, iOS 17.0, tvOS 17.0, visionOS 1.0, *)
    @Test func executorAnswersIsolationChecks() async {
        await RTC.run {
            RTC.shared.assumeIsolated { _ in }
        }
    }

    @Test func runExecutesOnTheRTCQueue() async {
        let onQueue = await RTC.run { RTC.isOnQueue }
        #expect(onQueue)
        #expect(!RTC.isOnQueue)
    }

    @Test func probeRunsWhenNothingBlocks() async {
        let width = ProcessInfo.processInfo.activeProcessorCount + 2
        let outcome = await poolStaysResponsive(release: {}) { _ in await Task.yield() }
        #expect(outcome.responsive)
        #expect(outcome.finishedBeforeProbe == width, "the harness does not observe completions")
    }

    struct ProbeOutcome {
        /// An unrelated task ran while the blockers were in flight.
        let responsive: Bool
        /// How many of the `width` blockers had returned by the time the probe ran. A test whose
        /// `work` is supposed to be stuck expects `0` here: without that check a probe can pass
        /// because nothing ever blocked, which proves nothing.
        let finishedBeforeProbe: Int
    }

    /// Saturates the cooperative pool with `width` tasks running `work`, then checks whether an
    /// unrelated task can still run. The probe is observed from a libdispatch thread, and
    /// `release` runs before the caller is resumed, so a frozen pool fails the test instead of
    /// hanging the process. The settle delay gives the blockers time to reach their blocking call.
    private func poolStaysResponsive(width: Int = ProcessInfo.processInfo.activeProcessorCount + 2,
                                     release: @escaping @Sendable () -> Void,
                                     work: @escaping @Sendable (Int) async -> Void) async -> ProbeOutcome
    {
        let probe = DispatchSemaphore(value: 0)
        let finished = Counter()
        for index in 0 ..< width {
            Task.detached {
                await work(index)
                finished.increment()
            }
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: 0.5)
                let finishedBeforeProbe = finished.value
                Task.detached { probe.signal() }
                let responsive = probe.wait(timeout: .now() + .seconds(2)) == .success
                release()
                continuation.resume(returning: ProbeOutcome(responsive: responsive,
                                                            finishedBeforeProbe: finishedBeforeProbe))
            }
        }
    }
}

/// Counts completions across the cooperative pool and a libdispatch thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Parks libwebrtc's signaling thread inside a peer-connection delegate callback until `release()`.
private final class SignalingThreadWedge: NSObject, LKRTCPeerConnectionDelegate, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let wedged = DispatchSemaphore(value: 0)
    private var peerConnection: LKRTCPeerConnection?
    private var dataChannel: LKRTCDataChannel?

    static func engage(afterCreatingDataChannel: Bool = false) async throws -> SignalingThreadWedge {
        let wedge = SignalingThreadWedge()
        let peerConnection = try #require(RTC.peerConnectionFactory.peerConnection(with: .liveKitDefault(),
                                                                                   constraints: .defaultPCConstraints,
                                                                                   delegate: wedge))
        wedge.peerConnection = peerConnection
        if afterCreatingDataChannel {
            wedge.dataChannel = peerConnection.dataChannel(forLabel: "wedge", configuration: .init())
        }
        let offer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LKRTCSessionDescription, Error>) in
            peerConnection.offer(for: .defaultPCConstraints) { sd, error in
                if let sd { continuation.resume(returning: sd) } else {
                    continuation.resume(throwing: error ?? LiveKitError(.invalidState, message: "no offer"))
                }
            }
        }
        // setLocalDescription blocks on the signaling thread and fires the wedging callback inline.
        nonisolated(unsafe) let pc = peerConnection
        DispatchQueue.global().async { pc.setLocalDescription(offer) { _ in } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                if wedge.wedged.wait(timeout: .now() + .seconds(20)) == .success {
                    continuation.resume()
                } else {
                    // Disarm before giving up. The gate is process-wide state: libwebrtc has one
                    // signaling thread per factory, so a callback arriving after this wedge was
                    // abandoned would park that thread with nobody left to release it and hang
                    // every later test that touches WebRTC.
                    wedge.release()
                    continuation.resume(throwing: LiveKitError(.timedOut, message: "signaling thread never entered the wedge"))
                }
            }
        }
        return wedge
    }

    func takeDataChannel() -> LKRTCDataChannel? {
        defer { dataChannel = nil }
        return dataChannel
    }

    /// Safe to call before the wedge is entered, and safe to call twice: the semaphore keeps the
    /// signal, so a callback that arrives later passes straight through.
    func release() {
        gate.signal()
        nonisolated(unsafe) let peerConnection = peerConnection
        self.peerConnection = nil
        DispatchQueue.global().async { peerConnection?.close() }
    }

    func peerConnection(_: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {
        guard stateChanged == .haveLocalOffer else { return }
        wedged.signal()
        gate.wait()
    }

    func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}
    func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}
    func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceConnectionState) {}
    func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState) {}
    func peerConnection(_: LKRTCPeerConnection, didGenerate _: LKRTCIceCandidate) {}
    func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
    func peerConnection(_: LKRTCPeerConnection, didOpen _: LKRTCDataChannel) {}
}
