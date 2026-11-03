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

@Suite(TestLimits.unit)
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

    /// The server's leave and its close frame arrive together: the leave reaches the delegate before the close frame
    /// fails the stream, so a removal cannot turn into a reconnect. The same message loop as `connect` runs it, and the
    /// delegate cleans the client up from inside its leave callback, as `Room` does.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1179"), .tags(.networking))
    func leaveIsHandledBeforeTheCloseThatFollows() async throws {
        let leave = try Livekit_SignalResponse.with {
            $0.leave = .with {
                $0.action = .disconnect
                $0.reason = .participantRemoved
            }
        }.serializedData()
        let frames = FakeWebSocketServer.binary([leave]) + FakeWebSocketServer.close(1000)
        let server = try FakeWebSocketServer(.frames(frames, withUpgrade: true))
        defer { server.cancel() }
        let client = SignalClient()
        let recorder = LeaveRecorder(client: client)
        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10,
                                                 onEvent: recorder.socketEvents.record)
        await client._delegate.set(delegate: recorder)
        await client.installMessageLoopForTest(socket, recorder: recorder)

        try await recorder.disconnected.wait()
        #expect(recorder.events.copy() == [.leave(awaited: true), .disconnected(.participantRemoved)])
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
            _ = try? await delegate.handled.wait()
        })
        await client._state.mutate { $0.connectionState = .connecting }
        await client._delegate.set(delegate: delegate)

        await client.resumeQueues()
        await client.cleanUp()

        let received = try await delegate.handled.wait()
        #expect(received == response.response)

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
        let payload: Livekit_TrickleRequest? = if case let .trickle(trickle)? = request.message {
            trickle
        } else {
            nil
        }
        let trickle = try #require(payload)
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

private extension SignalClient {
    func installMessageLoopForTest(_ socket: LiveKit.WebSocket, recorder: LeaveRecorder) {
        let loop = socket.subscribe(self) { client, message in
            await client.handleMessageForTest(message, from: socket, recorder: recorder)
        } onFailure: { client, error in
            await client.onWebSocketFailure(error, from: socket)
        }
        _state.mutate {
            $0.socket = socket
            $0.connectionState = .connected
            $0.messageLoopTask = loop
        }
    }

    func handleMessageForTest(_ message: URLSessionWebSocketTask.Message, from socket: LiveKit.WebSocket, recorder: LeaveRecorder) async {
        await onWebSocketMessage(message, from: socket)
        // Stay on SignalClient's actor: a detached response processor cannot enter before this marks the return.
        recorder.messageReturned.mutate { $0 = true }
    }
}

private final class LeaveRecorder: SignalClientTestDelegate {
    enum Event: Equatable { case leave(awaited: Bool), disconnected(LiveKitErrorType?) }
    let client: SignalClient
    let socketEvents = SocketEvents()
    let messageReturned = StateSync(false)
    let events = StateSync<[Event]>([])
    let disconnected = AsyncCompleter<Void>(label: "LeaveRecorder.disconnected", defaultTimeout: 5)

    init(client: SignalClient) {
        self.client = client
    }

    /// As `Room` handles a leave that disconnects: it cleans the signal client up before it returns.
    func signalClient(_: SignalClient, didReceiveLeave _: Livekit_LeaveRequest_Action, reason: Livekit_DisconnectReason, regions _: Livekit_RegionSettings?) async {
        // The socket can finish its close handshake while message delivery still awaits this callback.
        do {
            _ = try await socketEvents.teardown.wait()
        } catch {
            Issue.record(error)
        }
        let awaited = !messageReturned.copy()
        await client.cleanUp(withError: LiveKitError.from(reason: reason))
        events.mutate { $0.append(.leave(awaited: awaited)) }
    }

    func signalClient(_: SignalClient, didUpdateConnectionState newState: ConnectionState, oldState _: ConnectionState, disconnectError: LiveKitError?) async {
        guard newState == .disconnected else { return }
        events.mutate { $0.append(.disconnected(disconnectError?.type)) }
        disconnected.resume(returning: ())
    }
}

private final class QueueResumeDelegate: SignalClientTestDelegate {
    static let candidate = IceCandidate(sdp: "candidate:1 1 udp 1 127.0.0.1 12345 typ host", sdpMLineIndex: 0, sdpMid: "0")
    let handled = AsyncCompleter<Livekit_SignalResponse>(label: "Response handler finished sending", defaultTimeout: 5)

    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: LKRTCSessionDescription, offerId: UInt32) async {
        do {
            try await signalClient.send(answer: RTC.createSessionDescription(type: .answer, sdp: "answer"), offerId: offerId)
            try await signalClient.sendCandidate(candidate: Self.candidate, target: .subscriber)
            handled.resume(returning: .with { $0.offer = offer.toPBType(offerId: offerId) })
        } catch {
            handled.resume(throwing: error)
        }
    }

    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: LKRTCSessionDescription, offerId: UInt32) async {
        do {
            try await signalClient.sendCandidate(candidate: Self.candidate, target: .publisher)
            handled.resume(returning: .with { $0.answer = answer.toPBType(offerId: offerId) })
        } catch {
            handled.resume(throwing: error)
        }
    }

    func signalClient(_ signalClient: SignalClient, didReceiveMediaSectionsRequirement requirement: Livekit_MediaSectionsRequirement) async {
        do {
            try await signalClient.send(offer: RTC.createSessionDescription(type: .offer, sdp: "offer"), offerId: 18)
            handled.resume(returning: .with { $0.mediaSectionsRequirement = requirement })
        } catch {
            handled.resume(throwing: error)
        }
    }
}

private protocol SignalClientTestDelegate: SignalClientDelegate {}

private extension SignalClientTestDelegate {
    func signalClient(_: SignalClient, didUpdateConnectionState _: ConnectionState, oldState _: ConnectionState, disconnectError _: LiveKitError?) async {}
    func signalClient(_: SignalClient, didReceiveConnectResponse _: SignalClient.ConnectResponse) async {}
    func signalClient(_: SignalClient, didReceiveAnswer _: LKRTCSessionDescription, offerId _: UInt32) async {}
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
    func signalClient(_: SignalClient, didSubscribeTrack _: Track.Sid) async {}
    func signalClient(_: SignalClient, didReceiveMediaSectionsRequirement _: Livekit_MediaSectionsRequirement) async {}
    func signalClient(_: SignalClient, didReceiveDataTrackResponse _: Data) async {}
    func signalClient(_: SignalClient, didReceiveLeave _: Livekit_LeaveRequest_Action, reason _: Livekit_DisconnectReason, regions _: Livekit_RegionSettings?) async {}
}
