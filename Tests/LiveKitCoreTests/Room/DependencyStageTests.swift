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
        let connection = ConnectionDependencies(room: room)

        var stage = DependencyStage.idle
        try stage.begin(connection)

        #expect(stage.connection === connection)
        #expect(stage.join == nil)
    }

    @Test func beginWhileStagedThrows() throws {
        let room = Room()

        var stage = DependencyStage.idle
        try stage.begin(ConnectionDependencies(room: room))

        #expect(throws: LiveKitError.self) {
            try stage.begin(ConnectionDependencies(room: room))
        }
    }

    @Test func retireJoinWithoutJoinKeepsConnection() throws {
        let room = Room()
        let connection = ConnectionDependencies(room: room)

        var stage = DependencyStage.idle
        try stage.begin(connection)

        #expect(stage.retireJoin() == nil)
        #expect(stage.connection === connection)
    }

    @Test func endRetiresConnection() throws {
        let room = Room()
        let connection = ConnectionDependencies(room: room)

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
    }
}
