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

struct RoomSidTests {
    // MARK: - State.apply(roomInfo:)

    @Test func applyPopulatesSidWhenNonEmpty() {
        var state = makeState()
        var info = Livekit_Room()
        info.sid = "RM_abc"
        info.name = "my-room"

        state.apply(roomInfo: info)

        #expect(state.sid?.stringValue == "RM_abc")
        #expect(state.name == "my-room")
    }

    @Test func applyDoesNotOverwriteSidWithEmpty() {
        var state = makeState()
        state.sid = Room.Sid(from: "RM_existing")
        state.name = "existing-name"

        var info = Livekit_Room()
        info.sid = ""
        info.name = ""

        state.apply(roomInfo: info)

        #expect(state.sid?.stringValue == "RM_existing")
        #expect(state.name == "existing-name")
    }

    @Test func applyLeavesSidNilWhenEmptyAndPreviouslyUnset() {
        var state = makeState()
        var info = Livekit_Room()
        info.sid = ""

        state.apply(roomInfo: info)

        #expect(state.sid == nil)
    }

    @Test func applyUpdatesSidOnSubsequentNonEmptyValue() {
        var state = makeState()

        var first = Livekit_Room()
        first.sid = ""
        state.apply(roomInfo: first)
        #expect(state.sid == nil)

        var second = Livekit_Room()
        second.sid = "RM_late"
        state.apply(roomInfo: second)
        #expect(state.sid?.stringValue == "RM_late")
    }

    @Test func applyPreservesMaxParticipantsAndCreationTimeOnZero() {
        var state = makeState()
        state.maxParticipants = 50
        state.creationTime = Date(timeIntervalSince1970: 1000)

        let info = Livekit_Room() // all zero / empty

        state.apply(roomInfo: info)

        #expect(state.maxParticipants == 50)
        #expect(state.creationTime == Date(timeIntervalSince1970: 1000))
    }

    // MARK: - SignalClient delegate integration

    @Test func joinResponseWithEmptySidThenRoomUpdatePopulatesSid() async throws {
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

        #expect(room.sid?.stringValue == "RM_delivered_later")
        let awaited = try await room.sid()
        #expect(awaited.stringValue == "RM_delivered_later")
    }

    @Test func joinResponseWithSidResolvesAwaitedSid() async throws {
        let room = Room()

        var join = Livekit_JoinResponse()
        join.room.sid = "RM_from_join"
        join.room.name = "my-room"

        await room.signalClient(room.signalClient, didReceiveConnectResponse: .join(join))

        let awaited = try await room.sid()
        #expect(awaited.stringValue == "RM_from_join")
    }

    @Test func roomUpdateWithEmptySidDoesNotClearExistingSid() async {
        let room = Room()

        var join = Livekit_JoinResponse()
        join.room.sid = "RM_initial"
        await room.signalClient(room.signalClient, didReceiveConnectResponse: .join(join))
        #expect(room.sid?.stringValue == "RM_initial")

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
