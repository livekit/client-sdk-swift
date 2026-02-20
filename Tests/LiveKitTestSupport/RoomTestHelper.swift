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

/// Test helper equivalent to Android SDK's MockE2ETest infrastructure.
/// Creates a Room in a simulated connected state and provides methods to
/// simulate server events by calling Room's delegate methods directly,
/// bypassing the WebSocket layer.
///
/// Usage:
/// ```swift
/// let helper = RoomTestHelper()
/// let tracker = MyDelegateTracker()
/// helper.room.delegates.add(delegate: tracker)
/// await helper.simulateParticipantUpdate([...])
/// XCTAssertEqual(helper.room.remoteParticipants.count, 1)
/// ```
public final class RoomTestHelper: @unchecked Sendable {
    public let room: Room
    /// Mock WebSocket injected into the SignalClient for capturing sent messages.
    public let mockWebSocket: MockWebSocket

    public init(
        roomOptions: RoomOptions = RoomOptions(),
        connectOptions: ConnectOptions = ConnectOptions(),
        localSid: String = "PA_local",
        localIdentity: String = "local-user"
    ) {
        let mock = MockWebSocket()
        mockWebSocket = mock
        room = Room(connectOptions: connectOptions, roomOptions: roomOptions)
        room._state.mutate { $0.connectionState = .connected }
        let localInfo = TestData.participantInfo(sid: localSid, identity: localIdentity)
        room.localParticipant.set(info: localInfo, connectionState: .connected)
    }

    /// Injects the mock WebSocket and sets the SignalClient to connected state.
    /// Call this before testing send operations.
    public func connectSignalClient() async {
        await room.signalClient.setWebSocket(mockWebSocket)
        await room.signalClient.setConnectionState(.connected)
        await room.signalClient.resumeQueues()
    }

    // MARK: - Participant Management

    @discardableResult
    public func addRemoteParticipant(
        sid: String = "PA_r1",
        identity: String = "remote-1",
        name: String = "Remote User",
        tracks: [Livekit_TrackInfo] = []
    ) -> RemoteParticipant {
        let info = TestData.participantInfo(sid: sid, identity: identity, name: name, tracks: tracks)
        let participant = RemoteParticipant(info: info, room: room, connectionState: .connected)
        room._state.mutate {
            $0.remoteParticipants[Participant.Identity(from: identity)] = participant
        }
        return participant
    }

    // MARK: - SignalClient Delegate Simulation

    /// Simulate a join response from the server (via SignalClient delegate).
    public func simulateJoinResponse(_ response: Livekit_JoinResponse = TestData.joinResponse()) async {
        await room.signalClient(room.signalClient, didReceiveConnectResponse: .join(response))
    }

    /// Simulate room update (metadata, recording state, etc.)
    public func simulateRoomUpdate(_ roomInfo: Livekit_Room) async {
        await room.signalClient(room.signalClient, didUpdateRoom: roomInfo)
    }

    /// Simulate participant updates from the server.
    public func simulateParticipantUpdate(_ participants: [Livekit_ParticipantInfo]) async {
        await room.signalClient(room.signalClient, didUpdateParticipants: participants)
    }

    /// Simulate speaker updates (via SignalClient delegate path).
    public func simulateSignalSpeakerUpdate(_ speakers: [Livekit_SpeakerInfo]) async {
        await room.signalClient(room.signalClient, didUpdateSpeakers: speakers)
    }

    /// Simulate connection quality updates.
    public func simulateConnectionQuality(_ updates: [Livekit_ConnectionQualityInfo]) async {
        await room.signalClient(room.signalClient, didUpdateConnectionQuality: updates)
    }

    /// Simulate token refresh.
    public func simulateTokenRefresh(_ token: String) async {
        await room.signalClient(room.signalClient, didUpdateToken: token)
    }

    /// Simulate a leave message from the server.
    public func simulateLeave(
        action: Livekit_LeaveRequest.Action? = nil,
        reason: Livekit_DisconnectReason? = nil
    ) async {
        await room.signalClient(room.signalClient, didReceiveLeave: action ?? .disconnect, reason: reason ?? .clientInitiated, regions: nil)
    }

    /// Simulate remote mute update for a local track.
    public func simulateRemoteMute(trackSid: String, muted: Bool) async {
        await room.signalClient(room.signalClient, didUpdateRemoteMute: Track.Sid(from: trackSid), muted: muted)
    }

    /// Simulate subscription permission update.
    public func simulateSubscriptionPermission(_ update: Livekit_SubscriptionPermissionUpdate) async {
        await room.signalClient(room.signalClient, didUpdateSubscriptionPermission: update)
    }

    /// Simulate track stream state updates.
    public func simulateTrackStreamStates(_ states: [Livekit_StreamStateInfo]) async {
        await room.signalClient(room.signalClient, didUpdateTrackStreamStates: states)
    }

    /// Simulate subscribed quality/codec updates.
    public func simulateSubscribedCodecs(
        _ codecs: [Livekit_SubscribedCodec],
        qualities: [Livekit_SubscribedQuality],
        trackSid: String
    ) async {
        await room.signalClient(room.signalClient, didUpdateSubscribedCodecs: codecs, qualities: qualities, forTrackSid: trackSid)
    }

    /// Simulate room moved response.
    public func simulateRoomMoved(_ response: Livekit_RoomMovedResponse) async {
        await room.signalClient(room.signalClient, didReceiveRoomMoved: response)
    }

    /// Simulate track subscribed notification.
    public func simulateTrackSubscribed(trackSid: String) async {
        await room.signalClient(room.signalClient, didSubscribeTrack: Track.Sid(from: trackSid))
    }

    // MARK: - Engine Delegate Simulation (data channel path)

    /// Simulate a state transition via the engine delegate.
    public func simulateStateTransition(from oldState: Room.State, to newState: Room.State) {
        room.engine(room, didMutateState: newState, oldState: oldState)
    }

    /// Simulate speaker updates (via data channel / engine delegate path).
    public func simulateEngineSpeakerUpdate(_ speakers: [Livekit_SpeakerInfo]) {
        room.engine(room, didUpdateSpeakers: speakers)
    }

    /// Simulate receiving a data packet.
    public func simulateUserPacket(_ packet: Livekit_UserPacket, encryption: EncryptionType = .none) {
        room.engine(room, didReceiveUserPacket: packet, encryptionType: encryption)
    }

    /// Simulate receiving a transcription.
    public func simulateTranscription(_ transcription: Livekit_Transcription) {
        room.room(didReceiveTranscriptionPacket: transcription)
    }

    /// Simulate RPC response.
    public func simulateRpcResponse(_ response: Livekit_RpcResponse) {
        room.room(didReceiveRpcResponse: response)
    }

    /// Simulate RPC ack.
    public func simulateRpcAck(_ ack: Livekit_RpcAck) {
        room.room(didReceiveRpcAck: ack)
    }

    /// Simulate RPC request.
    public func simulateRpcRequest(_ request: Livekit_RpcRequest, from identity: String) {
        room.room(didReceiveRpcRequest: request, from: identity)
    }

    // MARK: - SignalClient._process Pipeline

    /// Inject a signal response through SignalClient's _process pipeline.
    /// This tests the full dispatch chain: signalResponse -> SignalClient._process -> Room delegate.
    /// Requires SignalClient to be in connected state.
    public func processSignalResponse(_ response: Livekit_SignalResponse) async {
        // Ensure SignalClient is in connected state (required by _process guard)
        await room.signalClient.setConnectionState(.connected)
        await room.signalClient._process(signalResponse: response)
    }
}
