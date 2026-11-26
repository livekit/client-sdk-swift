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
import LiveKitFFI
import Testing

struct NativeRoomMappingTests {
    @Test
    func snapshotPreservesMillisecondsAndPublicationOwnership() throws {
        let nativeRoom = NativeRoomInfo(sid: nil, name: "room", metadata: "metadata", state: .connected,
                                        lossyDcOptions: .init(bufferedAmountLowThreshold: 0), reliableDcOptions: .init(bufferedAmountLowThreshold: 0),
                                        emptyTimeout: 300, departureTimeout: 20, maxParticipants: 8, creationTime: 1_700_000_000_123,
                                        numPublishers: 1, numParticipants: 2, activeRecording: true)
        var state = Room.State(connectOptions: ConnectOptions(), roomOptions: RoomOptions())
        state.apply(roomInfo: nativeRoom)
        #expect(state.sid == nil)
        #expect(state.creationTime == Date(timeIntervalSince1970: 1_700_000_000.123))
        #expect(state.isRecording)
        #expect(state.maxParticipants == 8)

        let participant = NativeParticipant(identity: "alice", sid: "PA_alice", isLocal: false,
                                            name: "Alice", state: .active, kind: .bridge,
                                            kindDetails: [.bridgeRtsp], metadata: "", attributes: [:],
                                            isSpeaking: false, audioLevel: 0, connectionQuality: .excellent,
                                            joinedAt: 1_700_000_000_456, permission: nil, isEncrypted: false,
                                            disconnectReason: .unknownReason, clientProtocol: 2, capabilities: [.packetTrailer])
        let own = NativeTrackPublication(sid: "TR_alice", participantIdentity: "alice", name: "screen",
                                         kind: .video, source: .screenshare, isMuted: false,
                                         simulcasted: true, width: 1920, height: 1080,
                                         mimeType: "video/VP8", encryptionType: .gcm, remote: nil)
        var other = own
        other.participantIdentity = "bob"
        other.sid = "TR_bob"
        let remote = RemoteParticipant(info: participant, publications: [other, own], room: Room(), connectionState: .connected)
        #expect(remote.joinedAt == Date(timeIntervalSince1970: 1_700_000_000.456))
        #expect(remote.kind == .unknown) // Public Participant.Kind has no bridge case.
        #expect(remote.clientProtocol == .v2)
        #expect(remote.capabilities == [.packetTrailer])
        #expect(remote.permissions == ParticipantPermissions())
        #expect(remote.trackPublications.keys.map(\.stringValue) == ["TR_alice"])
        let track = try #require(remote.trackPublications.values.first)
        #expect(track.source == .screenShareVideo)
        #expect(track.encryptionType == .gcm)
        #expect(track.isSimulcasted)
        #expect(track.dimensions == Dimensions(width: 1920, height: 1080))
    }

    @Test(arguments: [(NativeDisconnectReason.clientInitiated, LiveKitErrorType.cancelled), (.duplicateIdentity, .duplicateIdentity),
                      (.serverShutdown, .serverShutdown), (.participantRemoved, .participantRemoved), (.roomDeleted, .roomDeleted),
                      (.stateMismatch, .stateMismatch), (.joinFailure, .joinFailure), (.migration, .unknown)])
    func disconnectReasonMapsToErrorType(_ reason: NativeDisconnectReason, _ expected: LiveKitErrorType) {
        #expect(reason.lkErrorType == expected)
    }
}
