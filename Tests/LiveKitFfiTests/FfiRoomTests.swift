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
import LiveKitFFI
import LiveKitTransport
import Testing

// This target has no dependency on the v2 LiveKit module.
@Suite(.timeLimit(.minutes(1)))
struct FfiRoomTests {
    @Test func generatedRoomLifecycle() async throws {
        LiveKitTransport.initialize()
        let url = ProcessInfo.processInfo.environment["LIVEKIT_TESTING_URL"] ?? "ws://127.0.0.1:19980"
        let name = "direct-\(UUID())"
        let token = try tokenGenerate(options: .init(videoGrants: .init(
            roomCreate: false, roomList: false, roomRecord: false, roomAdmin: false,
            roomJoin: true, room: name, destinationRoom: "", canPublish: true,
            canSubscribe: true, canPublishData: true, canPublishSources: [],
            canUpdateOwnMetadata: true, ingressAdmin: false, hidden: false,
            recorder: false, agent: false,
        ), identity: "direct"), credentials: .init(key: "devkey", secret: "secret"))
        let room = FfiRoom()
        let events = room.events(options: .init())
        do {
            let initial = try await room.connect(url: url, token: token, options: .init())
            #expect(initial.room?.name == name)
            #expect(initial.localParticipant?.identity == "direct")
            try await room.setMetadata(metadata: "direct metadata")
            var received = false
            while let update = try await events.next() {
                if case let .participantMetadataChanged(participant, _) = update.event {
                    #expect(participant.metadata == "direct metadata")
                    #expect(update.revision > initial.revision)
                    received = true
                    break
                }
            }
            #expect(received)
            await room.disconnect()
            #expect(room.state().connection == .disconnected)
            while try await events.next() != nil {}
        } catch {
            await room.disconnect()
            throw error
        }

        let cancelled = FfiRoom()
        await Task.detached { cancelled.cancel() }.value
        await #expect(throws: NativeSessionError.Cancelled) {
            _ = try await cancelled.connect(url: url, token: token, options: .init())
        }
        await cancelled.disconnect()
    }
}
