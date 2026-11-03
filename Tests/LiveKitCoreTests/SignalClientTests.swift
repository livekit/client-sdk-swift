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

struct SignalClientTests {
    /// Matches rust-sdks `get_join_response`/`get_reconnect_response`: from `cleanUp()` until the
    /// next Join/ReconnectResponse, only `join`, `reconnect` and `leave` get through.
    @Test func connectResponseGate() async {
        let client = SignalClient()
        let update = Livekit_SignalResponse.with { $0.update = .with { _ in } }

        await client.cleanUp()
        #expect(await client.passesConnectResponseGate(update) == false)
        #expect(await client.passesConnectResponseGate(.with { $0.leave = .with { _ in } }))
        #expect(await client.passesConnectResponseGate(update) == false, "leave must not open the gate")

        #expect(await client.passesConnectResponseGate(.with { $0.join = .with { _ in } }))
        #expect(await client.passesConnectResponseGate(update))

        await client.cleanUp()
        #expect(await client.passesConnectResponseGate(update) == false, "cleanUp must re-arm the gate")

        #expect(await client.passesConnectResponseGate(.with { $0.reconnect = .with { _ in } }))
        #expect(await client.passesConnectResponseGate(update))
    }

    enum QueuedResponse: CaseIterable {
        case offer
        case answer
        case mediaSectionsRequirement

        var response: Livekit_SignalResponse {
            switch self {
            case .offer:
                .with { $0.offer = .with {
                    $0.type = "offer"
                    $0.sdp = "offer"
                    $0.id = 17
                } }
            case .answer:
                .with { $0.answer = .with {
                    $0.type = "answer"
                    $0.sdp = "answer"
                    $0.id = 17
                } }
            case .mediaSectionsRequirement:
                .with { $0.mediaSectionsRequirement = .with { $0.numAudios = 1 } }
            }
        }
    }

    @Test(arguments: QueuedResponse.allCases)
    func detachedResponseHandlerCanSendRequests(response: QueuedResponse) async throws {
        let sent = StateSync<[Livekit_SignalRequest]>([])
        let delegate = QueueResumeDelegate()
        let client = try await SignalClient(testingResponse: response.response, requestProcessor: { request in
            sent.mutate { $0.append(request) }
        }, responseProcessed: {
            do {
                try await delegate.handled.wait()
            } catch {
                Issue.record(error)
            }
        })
        await client._state.mutate { $0.connectionState = .connecting }
        await client._delegate.set(delegate: delegate)

        await client.resumeQueues()
        await client.cleanUp()

        let requests = sent.copy()
        try #require(requests.count == (response == .offer ? 2 : 1))
        #expect(requests.allSatisfy { !$0.canBeQueued() })
        let first = try #require(requests.first)
        switch response {
        case .offer:
            #expect(first == Livekit_SignalRequest.with {
                $0.answer = .with {
                    $0.type = "answer"
                    $0.sdp = "answer"
                    $0.id = 17
                }
            })
            try expectCandidate(#require(requests.last), target: .subscriber)
        case .answer:
            try expectCandidate(first, target: .publisher)
        case .mediaSectionsRequirement:
            #expect(first == Livekit_SignalRequest.with {
                $0.offer = .with {
                    $0.type = "offer"
                    $0.sdp = "offer"
                    $0.id = 18
                }
            })
        }
    }

    private func expectCandidate(_ request: Livekit_SignalRequest, target: Livekit_SignalTarget) throws {
        guard case let .trickle(trickle)? = request.message else {
            Issue.record("Expected an ICE candidate request")
            return
        }
        #expect(trickle.target == target)
        let candidate = try JSONDecoder().decode(IceCandidate.self, from: Data(trickle.candidateInit.utf8))
        #expect(candidate.sdp == QueueResumeDelegate.candidate.sdp)
        #expect(candidate.sdpMid == QueueResumeDelegate.candidate.sdpMid)
        #expect(candidate.sdpMLineIndex == QueueResumeDelegate.candidate.sdpMLineIndex)
    }

    @Test func messageNameOmitsPayload() {
        let response = Livekit_SignalResponse.with { $0.refreshToken = "secret.jwt" }
        #expect(response.messageName == "refreshToken")
    }
}

private final class QueueResumeDelegate: SignalClientDelegate {
    static let candidate = IceCandidate(sdp: "candidate:1 1 udp 1 127.0.0.1 12345 typ host", sdpMLineIndex: 0, sdpMid: "0")
    let handled = AsyncCompleter<Void>(label: "Response handler finished sending", defaultTimeout: 5)

    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: LKRTCSessionDescription, offerId: UInt32) async {
        defer { handled.resume(returning: ()) }
        #expect(offer.type == .offer)
        #expect(offer.sdp == "offer")
        #expect(offerId == 17)
        do {
            try await signalClient.send(answer: RTC.createSessionDescription(type: .answer, sdp: "answer"), offerId: offerId)
            try await signalClient.sendCandidate(candidate: Self.candidate, target: .subscriber)
        } catch {
            Issue.record(error)
        }
    }

    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: LKRTCSessionDescription, offerId: UInt32) async {
        defer { handled.resume(returning: ()) }
        #expect(answer.type == .answer)
        #expect(answer.sdp == "answer")
        #expect(offerId == 17)
        do {
            try await signalClient.sendCandidate(candidate: Self.candidate, target: .publisher)
        } catch {
            Issue.record(error)
        }
    }

    func signalClient(_ signalClient: SignalClient, didReceiveMediaSectionsRequirement requirement: Livekit_MediaSectionsRequirement) async {
        defer { handled.resume(returning: ()) }
        #expect(requirement.numAudios == 1)
        do {
            try await signalClient.send(offer: RTC.createSessionDescription(type: .offer, sdp: "offer"), offerId: 18)
        } catch {
            Issue.record(error)
        }
    }

    func signalClient(_: SignalClient, didUpdateConnectionState _: ConnectionState, oldState _: ConnectionState, disconnectError _: LiveKitError?) async {}
    func signalClient(_: SignalClient, didReceiveConnectResponse _: SignalClient.ConnectResponse) async {}
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
    func signalClient(_: SignalClient, didReceiveLeave _: Livekit_LeaveRequest_Action, reason _: Livekit_DisconnectReason, regions _: Livekit_RegionSettings?) async {}
    func signalClient(_: SignalClient, didSubscribeTrack _: Track.Sid) async {}
    func signalClient(_: SignalClient, didReceiveDataTrackResponse _: Data) async {}
}
