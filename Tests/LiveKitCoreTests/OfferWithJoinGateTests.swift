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
import LiveKitWebRTC
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// The offer bundled with the JOIN request is answered over the signal channel. Were that
/// answer sent before the JoinResponse, the connect-response gate would drop it.
@Suite(.serialized, .tags(.e2e))
struct OfferWithJoinGateTests {
    @Test(arguments: [false, true])
    func staleSocketCallbacksAreIgnored(cancelled: Bool) async throws {
        let client = SignalClient()
        let url = try #require(URL(string: TestEnvironment.liveKitServerUrl()))
        let token = try TestEnvironment.liveKitServerToken(for: UUID().uuidString, identity: "gate",
                                                           canPublish: true, canPublishData: true,
                                                           canPublishSources: [], canSubscribe: true)
        do {
            try await client.connect(url, token, adaptiveStream: false, singlePeerConnection: false)
            let oldSocket = try #require(await client._state.socket)
            try await client.connect(url, token, adaptiveStream: false, singlePeerConnection: false)
            let currentSocket = try #require(await client._state.socket)
            #expect(oldSocket !== currentSocket)

            // Recreate the handshake window without racing the server's actual response.
            await client._state.mutate { $0.isAwaitingConnectResponse = true }
            let response = try Livekit_SignalResponse.with { $0.reconnect = .with { _ in } }.serializedData()
            let error = LiveKitError(.network)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    if cancelled {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    let socket = cancelled ? currentSocket : oldSocket
                    await client.onWebSocketMessage(.data(response), from: socket)
                    await client.onWebSocketFailure(error, from: socket)
                }
            }

            #expect(await client._state.isAwaitingConnectResponse, "stale callbacks must not open the gate")
            #expect(await client._state.socket === currentSocket, "stale failures must not close the current socket")
            #expect(await client.connectionState == .connected)

            await client.onWebSocketMessage(.data(response), from: currentSocket)
            #expect(await client._state.isAwaitingConnectResponse == false)
            await client.onWebSocketFailure(error, from: currentSocket)
            #expect(await client.connectionState == .disconnected)
        } catch {
            await client.cleanUp()
            throw error
        }
        await client.cleanUp()
    }

    /// A leave is enqueued from a detached task, which can run after its socket was replaced; it
    /// must not reach the delegate, where it would end the session the new socket carries.
    @Test func leaveEnqueuedAfterItsSocketWasReplacedIsDropped() async throws {
        let client = SignalClient()
        let recorder = SignalRecorder()
        await client._delegate.set(delegate: recorder)
        let url = try #require(URL(string: TestEnvironment.liveKitServerUrl()))
        let token = try TestEnvironment.liveKitServerToken(for: UUID().uuidString, identity: "gate",
                                                           canPublish: true, canPublishData: true,
                                                           canPublishSources: [], canSubscribe: true)
        do {
            try await client.connect(url, token, adaptiveStream: false, singlePeerConnection: false)
            let oldSocket = try #require(await client._state.socket)
            try await client.connect(url, token, adaptiveStream: false, singlePeerConnection: false)
            let currentSocket = try #require(await client._state.socket)

            func leave(_ reason: Livekit_DisconnectReason) throws -> (Livekit_SignalResponse, Data) {
                let response = Livekit_SignalResponse.with { $0.leave = .with { $0.action = .disconnect; $0.reason = reason } }
                return try (response, response.serializedData())
            }

            // Arrived on the old socket; its delayed enqueue runs only now.
            let stale = try leave(.duplicateIdentity)
            await client.enqueue(stale.0, encoded: stale.1, from: oldSocket)
            // Then one on the current socket, which is delivered.
            let current = try leave(.serverShutdown)
            await client.enqueue(current.0, encoded: current.1, from: currentSocket)

            try await recorder.leave.wait()
            #expect(recorder.leaveReasons == [.serverShutdown])
        } catch {
            await client.cleanUp()
            throw error
        }
        await client.cleanUp()
    }

    @Test func answerToJoinBundledOfferPassesTheGate() async throws {
        let room = Room()
        let publisher = try await EarlyPublisher.make(room: room, rtcConfiguration: .liveKitDefault())
        let offer = try #require(publisher.offer, "single PC mode bundles an offer with the JOIN")

        let client = SignalClient()
        let recorder = SignalRecorder()
        await client._delegate.set(delegate: recorder)

        let url = try #require(URL(string: TestEnvironment.liveKitServerUrl()))
        let token = try TestEnvironment.liveKitServerToken(for: UUID().uuidString, identity: "gate",
                                                           canPublish: true, canPublishData: true,
                                                           canPublishSources: [], canSubscribe: true)
        try await client.connect(url, token, adaptiveStream: false, singlePeerConnection: true, publisherOffer: offer)
        await client.resumeQueues()

        let answeredOfferId = try await recorder.answer.wait()
        #expect(answeredOfferId == offer.id)

        await client.cleanUp()
        await publisher.close()
    }
}

private final class SignalRecorder: SignalClientDelegate {
    let answer = AsyncCompleter<UInt32>(label: "Answer", defaultTimeout: 5)
    let leave = AsyncCompleter<Void>(label: "Leave", defaultTimeout: 5)
    private let _leaveReasons = StateSync<[Livekit_DisconnectReason]>([])

    var leaveReasons: [Livekit_DisconnectReason] { _leaveReasons.copy() }

    func signalClient(_: SignalClient, didReceiveAnswer _: LKRTCSessionDescription, offerId: UInt32) async {
        answer.resume(returning: offerId)
    }

    func signalClient(_: SignalClient, didUpdateConnectionState _: ConnectionState, oldState _: ConnectionState, disconnectError _: LiveKitError?) async {}
    func signalClient(_: SignalClient, didReceiveConnectResponse _: SignalClient.ConnectResponse) async {}
    func signalClient(_: SignalClient, didReceiveOffer _: LKRTCSessionDescription, offerId _: UInt32) async {}
    func signalClient(_: SignalClient, didReceiveIceCandidate _: IceCandidate, target _: Livekit_SignalTarget) async {}
    func signalClient(_: SignalClient, didUnpublishLocalTrack _: Livekit_TrackUnpublishedResponse) async {}
    func signalClient(_: SignalClient, didUpdateParticipants _: [Livekit_ParticipantInfo]) async {}
    func signalClient(_: SignalClient, didReceiveEncodedResponse _: SignalClient.EncodedResponse) async {}
    func signalClient(_: SignalClient, didUpdateRoom _: Livekit_Room) async {}
    func signalClient(_: SignalClient, didUpdateSpeakers _: [Livekit_SpeakerInfo]) async {}
    func signalClient(_: SignalClient, didUpdateConnectionQuality _: [Livekit_ConnectionQualityInfo]) async {}
    func signalClient(_: SignalClient, didUpdateRemoteMute _: Track.Sid, muted _: Bool) async {}
    func signalClient(_: SignalClient, didUpdateTrackStreamStates _: [Livekit_StreamStateInfo]) async {}
    func signalClient(_: SignalClient, didUpdateSubscribedCodecs _: [Livekit_SubscribedCodec], qualities _: [Livekit_SubscribedQuality], forTrackSid _: String) async {}
    func signalClient(_: SignalClient, didReceiveRoomMoved _: Livekit_RoomMovedResponse) async {}
    func signalClient(_: SignalClient, didUpdateSubscriptionPermission _: Livekit_SubscriptionPermissionUpdate) async {}
    func signalClient(_: SignalClient, didUpdateToken _: String) async {}
    func signalClient(_: SignalClient, didReceiveLeave _: Livekit_LeaveRequest_Action, reason: Livekit_DisconnectReason, regions _: Livekit_RegionSettings?) async {
        _leaveReasons.mutate { $0.append(reason) }
        leave.resume(returning: ())
    }

    func signalClient(_: SignalClient, didSubscribeTrack _: Track.Sid) async {}
    func signalClient(_: SignalClient, didReceiveMediaSectionsRequirement _: Livekit_MediaSectionsRequirement) async {}
    func signalClient(_: SignalClient, didReceiveDataTrackResponse _: Data) async {}
}
