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
import LiveKitUniFFI

/// Framework-agnostic test environment utilities (no XCTest/Testing dependency).
public enum TestEnvironment {
    public static func readEnvironmentString(for key: String, defaultValue: String) -> String {
        if let string = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            return string
        }
        return defaultValue
    }

    public static func liveKitServerUrl() -> String {
        readEnvironmentString(for: "LIVEKIT_TESTING_URL", defaultValue: "ws://localhost:7880")
    }

    // swiftlint:disable:next function_parameter_count
    public static func liveKitServerToken(for room: String,
                                          identity: String,
                                          canPublish: Bool,
                                          canPublishData: Bool,
                                          canPublishSources: Set<Track.Source>,
                                          canSubscribe: Bool) throws -> String
    {
        let apiKey = readEnvironmentString(for: "LIVEKIT_TESTING_API_KEY", defaultValue: "devkey")
        let apiSecret = readEnvironmentString(for: "LIVEKIT_TESTING_API_SECRET", defaultValue: "secret")

        let tokenGenerator = TokenGenerator(apiKey: apiKey,
                                            apiSecret: apiSecret,
                                            identity: identity)

        tokenGenerator.videoGrants = VideoGrants(
            roomCreate: false,
            roomList: false,
            roomRecord: false,
            roomAdmin: false,
            roomJoin: true,
            room: room,
            destinationRoom: "",
            canPublish: canPublish,
            canSubscribe: canSubscribe,
            canPublishData: canPublishData,
            canPublishSources: canPublishSources.map(String.init),
            canUpdateOwnMetadata: false,
            ingressAdmin: false,
            hidden: false,
            recorder: false,
        )

        return try tokenGenerator.sign()
    }

    /// Single-room convenience. Connects one Room, executes the block, then disconnects.
    public static func withRoom(_ options: RoomTestingOptions = RoomTestingOptions(),
                                _ block: @escaping (Room) async throws -> Void) async throws
    {
        try await withRooms([options]) { rooms in
            try await block(rooms[0])
        }
    }

    // Set up variable number of Rooms, connect them, wait for participants to discover each other,
    // execute the block, then disconnect. Framework-agnostic (no XCTest/Testing dependency).
    public static func withRooms(_ options: [RoomTestingOptions] = [],
                                 _ block: @escaping ([Room]) async throws -> Void) async throws
    {
        let roomName = UUID().uuidString
        let sharedKey = UUID().uuidString

        let rooms = try options.enumerated().map {
            let connectOptions = ConnectOptions(
                enableMicrophone: $0.element.enableMicrophone,
                clientProtocol: $0.element.clientProtocol ?? ConnectOptions().clientProtocol,
            )

            let encryptionOptions = $0.element.encryptionOptions ?? EncryptionOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: sharedKey))
            let roomOptions = RoomOptions(encryptionOptions: encryptionOptions, reportRemoteTrackStatistics: true, singlePeerConnection: $0.element.singlePeerConnection)

            let room = Room(delegate: $0.element.delegate, connectOptions: connectOptions, roomOptions: roomOptions)
            let identity = "identity-\($0.offset)"

            let url = $0.element.url ?? liveKitServerUrl()

            let lkToken = try liveKitServerToken(for: roomName,
                                                 identity: identity,
                                                 canPublish: $0.element.canPublish,
                                                 canPublishData: $0.element.canPublishData,
                                                 canPublishSources: $0.element.canPublishSources,
                                                 canSubscribe: $0.element.canSubscribe)
            let token = $0.element.token ?? lkToken

            print("Token: \(token) for room: \(roomName)")

            return RoomFixture(room: room,
                               identity: identity,
                               url: url,
                               token: token)
        }

        let allRooms = rooms.map(\.room)

        // Tear down on every exit path: a `Room` keeps itself alive through its
        // signaling and transport tasks, so an early exit without `disconnect()`
        // leaks a live Room into the rest of the test process.
        do {
            try await connectAndDiscover(rooms, roomName: roomName)
            try await block(allRooms)
        } catch {
            await teardown(allRooms)
            throw error
        }
        await teardown(allRooms)

        // Allow the server to fully tear down resources before the next test.
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    private struct RoomFixture {
        let room: Room
        let identity: String
        let url: String
        let token: String
    }

    private static func connectAndDiscover(_ rooms: [RoomFixture], roomName: String) async throws {
        // Connect all Rooms concurrently (retry on transient failure)
        try await Task.retrying(totalAttempts: 3, retryDelay: 2) { _, _ in
            try await withThrowingTaskGroup { group in
                for element in rooms {
                    group.addTask {
                        try await element.room.connect(url: element.url, token: element.token)
                        guard element.room.localParticipant.identity != nil else {
                            throw LiveKitError(.invalidState, message: "LocalParticipant.identity is nil after connect")
                        }
                        print("LocalParticipant.identity: \(String(describing: element.room.localParticipant.identity))")
                    }
                }
                try await group.waitForAll()
            }
        }.value

        let observerToken = try liveKitServerToken(for: roomName,
                                                   identity: "observer",
                                                   canPublish: true,
                                                   canPublishData: true,
                                                   canPublishSources: [],
                                                   canSubscribe: true)

        print("Observer token: \(observerToken) for room: \(roomName)")

        // Wait for all participants to discover each other using async polling
        if rooms.count >= 2 {
            let allIdentities = rooms.map(\.identity)

            for fixture in rooms {
                let (room, identity) = (fixture.room, fixture.identity)
                let exceptSelfIdentity = allIdentities.filter { $0 != identity }
                print("Will wait for remote participants: \(exceptSelfIdentity)")

                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    let remoteIdentities = room.remoteParticipants.map(\.key.stringValue)
                    if remoteIdentities.hasSameElements(as: exceptSelfIdentity) {
                        break
                    }
                    try await Task.sleep(nanoseconds: 200_000_000) // 200ms
                }

                let remoteIdentities = room.remoteParticipants.map(\.key.stringValue)
                guard remoteIdentities.hasSameElements(as: exceptSelfIdentity) else {
                    throw LiveKitError(.timedOut, message: "Timed out waiting for participants for \(identity)")
                }
            }
        }
    }

    /// Gracefully unpublish all tracks then disconnect, best-effort.
    private static func teardown(_ rooms: [Room]) async {
        await withTaskGroup(of: Void.self) { group in
            for room in rooms {
                group.addTask {
                    await room.localParticipant.unpublishAll()
                    await room.disconnect()
                }
            }
        }
    }
}
