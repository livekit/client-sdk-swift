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
            recorder: false
        )

        return try tokenGenerator.sign()
    }

    /// Set up variable number of Rooms, connect them, wait for participants to discover each other,
    /// execute the block, then disconnect. Framework-agnostic (no XCTest/Testing dependency).
    // swiftlint:disable:next function_body_length
    public static func withRooms(_ options: [RoomTestingOptions] = [],
                                 _ block: @escaping ([Room]) async throws -> Void) async throws
    {
        let roomName = UUID().uuidString
        let sharedKey = UUID().uuidString

        let rooms = try options.enumerated().map {
            let connectOptions = ConnectOptions(enableMicrophone: $0.element.enableMicrophone)

            let encryptionOptions = $0.element.encryptionOptions ?? EncryptionOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: sharedKey))
            let roomOptions = RoomOptions(encryptionOptions: encryptionOptions, reportRemoteTrackStatistics: true)

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

            return (room: room,
                    identity: identity,
                    url: url,
                    token: token)
        }

        // Connect all Rooms concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
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

            for (room, identity, _, _) in rooms {
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

        let allRooms = rooms.map(\.room)
        // Execute block
        try await block(allRooms)

        // Disconnect all Rooms concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for element in rooms {
                group.addTask {
                    await element.room.disconnect()
                }
            }
            try await group.waitForAll()
        }
    }
}
