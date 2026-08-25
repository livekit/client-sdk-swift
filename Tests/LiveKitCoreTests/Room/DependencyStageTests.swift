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

/// Verifies the transition contract of the dependency stage: payloads are staged and retired
/// only through the transitions, a connection survives a join retirement, and ending the stage
/// hands every payload back exactly once.
struct DependencyStageTests {
    @Test func beginStagesConnection() throws {
        let room = Room()
        let connection = ConnectionDependencies(room: room, roomOptions: RoomOptions())

        var stage = DependencyStage.idle
        try stage.begin(connection)

        #expect(stage.connection === connection)
        #expect(stage.join == nil)
    }

    @Test func beginWhileStagedThrows() throws {
        let room = Room()

        var stage = DependencyStage.idle
        try stage.begin(ConnectionDependencies(room: room, roomOptions: RoomOptions()))

        #expect(throws: LiveKitError.self) {
            try stage.begin(ConnectionDependencies(room: room, roomOptions: RoomOptions()))
        }
    }

    @Test func retireJoinWithoutJoinKeepsConnection() throws {
        let room = Room()
        let connection = ConnectionDependencies(room: room, roomOptions: RoomOptions())

        var stage = DependencyStage.idle
        try stage.begin(connection)

        #expect(stage.retireJoin() == nil)
        #expect(stage.connection === connection)
    }

    @Test func endRetiresConnection() throws {
        let room = Room()
        let connection = ConnectionDependencies(room: room, roomOptions: RoomOptions())

        var stage = DependencyStage.idle
        try stage.begin(connection)

        let retired = stage.end()
        #expect(retired.connection === connection)
        #expect(retired.join == nil)
        #expect(stage == .idle)
        #expect(stage.connection == nil)
    }

    @Test func endFromIdleRetiresNothing() {
        var stage = DependencyStage.idle

        let retired = stage.end()
        #expect(retired.connection == nil)
        #expect(retired.join == nil)
        #expect(stage == .idle)
    }

    @Test func freshRoomStartsIdle() {
        let room = Room()
        #expect(room._state.stage == .idle)
        #expect(room.dataTracks == nil)
        #expect(room._state.transport == nil)
        #expect(room.e2eeManager == nil)
    }

    @Test func e2eeManagerScopesToConnection() throws {
        let encryptionOptions = EncryptionOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: "stage-test"))
        let room = Room()

        // Idle: the facade has no connection to read or write through.
        room.e2eeManager = E2EEManager(options: encryptionOptions)
        #expect(room.e2eeManager == nil)

        // Built outside the lock, like connect() — its construction touches Room state.
        let dependencies = ConnectionDependencies(room: room, roomOptions: RoomOptions(encryptionOptions: encryptionOptions))
        try room._state.mutate { try $0.stage.begin(dependencies) }
        #expect(room.e2eeManager != nil, "Staging a connection derives the manager from the room options")

        let replacement = E2EEManager(options: encryptionOptions)
        room.e2eeManager = replacement
        #expect(room.e2eeManager === replacement, "The setter writes through to the connection's cell")

        _ = room._state.mutate { $0.stage.end() }
        #expect(room.e2eeManager == nil, "The manager is released with its connection")
    }
}
