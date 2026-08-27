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
        func transport(_: Transport, didAddTrack _: LKRTCMediaStreamTrack, rtpReceiver _: LKRTCRtpReceiver, streams _: [LKRTCMediaStream]) {}
        func transport(_: Transport, didRemoveTrack _: LKRTCMediaStreamTrack) {}
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

        let responsive = await poolStaysResponsive(width: width, release: wedge.release) { index in
            await transports[index].close()
        }

        #expect(responsive)
    }

    /// `Track.start()` → `enable()` → `set_enabled`, which blocks on the signaling thread; a
    /// non-isolated call site that hops through `RTC.run`.
    @Test func trackEnableKeepsTheCooperativePoolResponsive() async throws {
        let width = ProcessInfo.processInfo.activeProcessorCount + 2
        let tracks = (0 ..< width).map { _ in TestAudioTrack() }
        let wedge = try await SignalingThreadWedge.engage()

        let responsive = await poolStaysResponsive(width: width, release: wedge.release) { index in
            _ = try? await tracks[index].disable()
        }

        #expect(responsive)
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

        let responsive = await poolStaysResponsive(width: width, release: wedge.release) { index in
            holders[index].track = nil
        }

        #expect(responsive)
    }

    /// A parked channel release blocks the RTC executor while the signaling thread is stalled.
    /// Building a configuration — the first thing `Room.connect()` does — must not wait on it.
    @Test func configurationBuildsWithoutTheRTCExecutor() async throws {
        let wedge = try await SignalingThreadWedge.engage(afterCreatingDataChannel: true)
        // Dropping the last channel reference is the blocking part: the proxy destructor runs on
        // the signaling thread.
        parkChannelRelease(wedge.takeDataChannel(), closing: true)

        let responsive = await poolStaysResponsive(release: wedge.release) { _ in
            _ = LKRTCConfiguration.liveKitDefault()
        }

        #expect(responsive)
    }

    @Test func runExecutesOnTheRTCQueue() async {
        let onQueue = await RTC.run { RTC.isOnQueue }
        #expect(onQueue)
        #expect(!RTC.isOnQueue)
    }

    @Test func probeRunsWhenNothingBlocks() async {
        let responsive = await poolStaysResponsive(release: {}) { _ in await Task.yield() }
        #expect(responsive)
    }

    /// Saturates the cooperative pool with `width` tasks running `work`, then checks whether an
    /// unrelated task can still run. The probe is observed from a libdispatch thread, and
    /// `release` runs before the caller is resumed, so a frozen pool fails the test instead of
    /// hanging the process. The settle delay gives the blockers time to reach their blocking call.
    private func poolStaysResponsive(width: Int = ProcessInfo.processInfo.activeProcessorCount + 2,
                                     release: @escaping @Sendable () -> Void,
                                     work: @escaping @Sendable (Int) async -> Void) async -> Bool
    {
        let probe = DispatchSemaphore(value: 0)
        for index in 0 ..< width {
            Task.detached { await work(index) }
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                Thread.sleep(forTimeInterval: 0.5)
                Task.detached { probe.signal() }
                let responsive = probe.wait(timeout: .now() + .seconds(2)) == .success
                release()
                continuation.resume(returning: responsive)
            }
        }
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
            wedge.dataChannel = try #require(peerConnection.dataChannel(forLabel: "wedge", configuration: .init()))
        }
        let offer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LKRTCSessionDescription, Error>) in
            peerConnection.offer(for: .defaultPCConstraints) { sd, error in
                if let sd { continuation.resume(returning: sd) } else {
                    continuation.resume(throwing: error ?? LiveKitError(.invalidState, message: "no offer"))
                }
            }
        }
        // setLocalDescription blocks on the signaling thread and fires the wedging callback inline.
        DispatchQueue.global().async { peerConnection.setLocalDescription(offer) { _ in } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                if wedge.wedged.wait(timeout: .now() + .seconds(5)) == .success {
                    continuation.resume()
                } else {
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

    func release() {
        gate.signal()
        let peerConnection = peerConnection
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
