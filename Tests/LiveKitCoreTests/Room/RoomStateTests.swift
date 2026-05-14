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

struct RoomStateTests {
    // MARK: - apply(roomInfo:): sid and name

    struct ApplyCase {
        let initialSid: String?
        let initialName: String?
        let infoSid: String
        let infoName: String
        let expectedSid: String?
        let expectedName: String?
    }

    /// `apply(roomInfo:)` never overwrites a known `sid` or `name` with an empty value;
    /// non-empty values always replace.
    @Test(arguments: [
        ApplyCase(initialSid: nil, initialName: nil, infoSid: "RM_a", infoName: "n",
                  expectedSid: "RM_a", expectedName: "n"),
        ApplyCase(initialSid: nil, initialName: nil, infoSid: "", infoName: "",
                  expectedSid: nil, expectedName: nil),
        ApplyCase(initialSid: "RM_keep", initialName: "keep", infoSid: "", infoName: "",
                  expectedSid: "RM_keep", expectedName: "keep"),
        ApplyCase(initialSid: "RM_old", initialName: "old", infoSid: "RM_new", infoName: "new",
                  expectedSid: "RM_new", expectedName: "new"),
    ])
    func applyMergesSidAndName(_ c: ApplyCase) {
        var state = makeState()
        if let sid = c.initialSid { state.sid = Room.Sid(from: sid) }
        state.name = c.initialName

        var info = Livekit_Room()
        info.sid = c.infoSid
        info.name = c.infoName
        state.apply(roomInfo: info)

        #expect(state.sid?.stringValue == c.expectedSid)
        #expect(state.name == c.expectedName)
    }

    /// `apply(roomInfo:)` preserves existing `maxParticipants` and `creationTime` when info reports zero.
    @Test func applyPreservesMaxParticipantsAndCreationTimeOnZero() {
        var state = makeState()
        state.maxParticipants = 50
        state.creationTime = Date(timeIntervalSince1970: 1000)

        state.apply(roomInfo: Livekit_Room())

        #expect(state.maxParticipants == 50)
        #expect(state.creationTime == Date(timeIntervalSince1970: 1000))
    }

    // MARK: - SignalClient delegate (Room.sid() flow)

    /// Issue #1009: SID delivered in a later `RoomUpdate` after an empty `JoinResponse.room.sid`.
    @Test func joinWithEmptySidThenRoomUpdatePopulatesSid() async throws {
        let room = Room()

        var join = Livekit_JoinResponse()
        join.room.sid = ""
        join.room.name = "my-room"
        await room.signalClient(room.signalClient, didReceiveConnectResponse: .join(join))

        #expect(room.sid == nil)
        #expect(room.name == "my-room")

        var update = Livekit_Room()
        update.sid = "RM_delivered_later"
        update.name = "my-room"
        await room.signalClient(room.signalClient, didUpdateRoom: update)

        let awaited = try await room.sid()
        #expect(awaited.stringValue == "RM_delivered_later")
    }

    @Test func joinWithSidResolvesAwaitedSid() async throws {
        let room = Room()

        var join = Livekit_JoinResponse()
        join.room.sid = "RM_from_join"
        await room.signalClient(room.signalClient, didReceiveConnectResponse: .join(join))

        let awaited = try await room.sid()
        #expect(awaited.stringValue == "RM_from_join")
    }

    @Test func roomUpdateWithEmptySidDoesNotClearExistingSid() async {
        let room = Room()

        var join = Livekit_JoinResponse()
        join.room.sid = "RM_initial"
        await room.signalClient(room.signalClient, didReceiveConnectResponse: .join(join))

        var update = Livekit_Room()
        update.sid = ""
        await room.signalClient(room.signalClient, didUpdateRoom: update)

        #expect(room.sid?.stringValue == "RM_initial")
    }

    // MARK: - Helpers

    private func makeState() -> Room.State {
        Room.State(connectOptions: ConnectOptions(), roomOptions: RoomOptions())
    }
}
