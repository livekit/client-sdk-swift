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

@Suite(.serialized, .tags(.e2e), TestLimits.e2e) final class RoomTests: @unchecked Sendable {
    @Test func roomProperties() async throws {
        try await TestEnvironment.withRoom { room in
            // SID
            let sid = try await room.sid()
            print("Room.sid(): \(String(describing: sid))")
            #expect(sid.stringValue.starts(with: "RM_"))

            // creationTime
            #expect(room.creationTime != nil)
            print("Room.creationTime: \(String(describing: room.creationTime))")
        }
    }

    @Test func participantCleanUp() async throws {
        // Create 2 Rooms
        try await TestEnvironment.withRooms([RoomTestingOptions(delegate: self), RoomTestingOptions(delegate: self)]) { _ in
            // Nothing to do here
        }
    }

    #if targetEnvironment(macCatalyst)
    @Test(.disabled("Room resources may not deallocate on Mac Catalyst, causing CI timeout"))
    #else
    @Test
    #endif
    func resourcesCleanUp() async throws {
        var refs = WeakRoomRefs()

        try await TestEnvironment.withRoom { room in
            await refs.capture(from: room)
        }

        // Allow time for deallocation after withRooms returns (rooms disconnected)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        refs.expectAllNil()
    }

    /// Verify that cleanUp() runs to completion even when called from a
    /// cancelled Task — the scenario that occurs when a reconnect task is
    /// cancelled by disconnect() or a newer reconnect.
    @Test func cleanUpRunsWhenTaskIsCancelled() async throws {
        try await TestEnvironment.withRoom { room in
            #expect(room.connectionState == .connected)

            // Call cleanUp from a cancelled Task context — reproduces the
            // reconnect-cancellation scenario where Task.isCancelled is true.
            let task = Task {
                do { try await Task.sleep(nanoseconds: NSEC_PER_SEC * 60) } catch {}
                #expect(Task.isCancelled)
                await room.cleanUp()
            }
            task.cancel()
            _ = await task.result

            // Verify cleanup actually ran (not skipped due to cancellation)
            #expect(room.connectionState == .disconnected)

            #expect(room.nativeSession.copy() == nil)
        }

        // Allow time for deallocation
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    /// Once teardown has begun there is no session to send through, so the send has to fail rather
    /// than hang — `.disconnecting` included.
    @Test(arguments: [ConnectionState.disconnected, .disconnecting])
    func sendDataPacketFailsWhileTearingDown(state: ConnectionState) async throws {
        let room = Room()
        room._state.mutate { $0.connectionState = state }

        await #expect(throws: LiveKitError.self) {
            try await room.localParticipant.publish(data: Data())
        }
    }
}

private struct WeakRoomRefs: @unchecked Sendable {
    weak var nativeDriver: NativeRoomDriver?
    weak var dataStreams: DataStreams?
    weak var e2eeManager: E2EEManager?
    weak var preConnectBuffer: PreConnectAudioBuffer?
    weak var delegates: MulticastDelegate<RoomDelegate>?
    weak var activeParticipantCompleters: CompleterMapActor<Void>?
    weak var localParticipant: LocalParticipant?
    var remoteParticipantChecks: [() -> Bool] = []
    weak var state: StateSync<Room.State>?
    weak var room: Room?

    mutating func capture(from room: Room) async {
        nativeDriver = room.nativeDriver
        dataStreams = room.dataStreams
        if let mgr = room.e2eeManager { e2eeManager = mgr }
        preConnectBuffer = room.preConnectBuffer
        delegates = room.delegates
        activeParticipantCompleters = room.activeParticipantCompleters
        localParticipant = room.localParticipant

        for remoteParticipant in room.remoteParticipants.values {
            remoteParticipantChecks.append { [weak remoteParticipant] in remoteParticipant == nil }
        }

        state = room._state
        self.room = room
    }

    func expectAllNil() {
        #expect(nativeDriver == nil, "Leaked object: NativeRoomDriver")
        #expect(dataStreams == nil, "Leaked object: DataStreams")
        #expect(e2eeManager == nil, "Leaked object: E2EEManager")
        #expect(preConnectBuffer == nil, "Leaked object: PreConnectBuffer")
        #expect(delegates == nil, "Leaked object: Delegates")
        #expect(activeParticipantCompleters == nil, "Leaked object: ActiveParticipantCompleters")
        #expect(localParticipant == nil, "Leaked object: LocalParticipant")
        for check in remoteParticipantChecks {
            #expect(check(), "Leaked object: RemoteParticipant")
        }
        #expect(state == nil, "Leaked object: Room.State")
        #expect(room == nil, "Leaked object: Room")
    }
}

extension RoomTests: RoomDelegate {
    func room(_: Room, participantDidDisconnect participant: RemoteParticipant) {
        print("participantDidDisconnect: \(participant)")
        // Check issue: https://github.com/livekit/client-sdk-swift/issues/300
        // participant.identity is null in participantDidDisconnect delegate
        #expect(participant.identity != nil, "participant.identity is nil in participantDidDisconnect delegate")
    }
}
