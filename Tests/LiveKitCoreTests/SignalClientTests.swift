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
        // The order is what the test checks, and a lost leave shows only when the failure wins a race: many rounds.
        for round in 0 ..< 50 {
            let frames = FakeWebSocketServer.binary([leave]) + FakeWebSocketServer.close(1000)
            let server = try FakeWebSocketServer(.frames(frames, withUpgrade: true))
            defer { server.cancel() }
            let socket = try await LiveKit.WebSocket(url: server.url(), headers: [], timeoutInterval: 10)
            let client = SignalClient()
            let recorder = LeaveRecorder(client: client)
            await client._delegate.set(delegate: recorder)
            await client.installMessageLoopForTest(socket)

            try await recorder.disconnected.wait()
            #expect(recorder.events.copy() == [.leave, .disconnected(.participantRemoved)], "Round \(round)")
        }
    }

    @Test func messageNameOmitsPayload() {
        let response = Livekit_SignalResponse.with { $0.refreshToken = "secret.jwt" }
        #expect(response.messageName == "refreshToken")
    }
}

private extension SignalClient {
    func installMessageLoopForTest(_ socket: LiveKit.WebSocket) {
        let loop = socket.subscribe(self) { client, message in
            await client.onWebSocketMessage(message, from: socket)
        } onFailure: { client, error in
            await client.onWebSocketFailure(error, from: socket)
        }
        _state.mutate {
            $0.socket = socket
            $0.connectionState = .connected
            $0.messageLoopTask = loop
        }
    }
}

private final class LeaveRecorder: SignalClientDelegate {
    enum Event: Equatable { case leave, disconnected(LiveKitErrorType?) }
    let client: SignalClient
    let events = StateSync<[Event]>([])
    let disconnected = AsyncCompleter<Void>(label: "LeaveRecorder.disconnected", defaultTimeout: 5)

    init(client: SignalClient) {
        self.client = client
    }

    /// As `Room` handles a leave that disconnects: it cleans the signal client up before it returns.
    func signalClient(_: SignalClient, didReceiveLeave _: Livekit_LeaveRequest_Action, reason: Livekit_DisconnectReason, regions _: Livekit_RegionSettings?) async {
        await client.cleanUp(withError: LiveKitError.from(reason: reason))
        events.mutate { $0.append(.leave) }
    }

    func signalClient(_: SignalClient, didUpdateConnectionState newState: ConnectionState, oldState _: ConnectionState, disconnectError: LiveKitError?) async {
        guard newState == .disconnected else { return }
        events.mutate { $0.append(.disconnected(disconnectError?.type)) }
        disconnected.resume(returning: ())
    }

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
}
