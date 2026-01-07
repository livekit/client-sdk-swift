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

public struct RoomTestingOptions {
    public let delegate: RoomDelegate?
    public let url: String?
    public let token: String?
    public let enableMicrophone: Bool
    public let encryptionOptions: EncryptionOptions?

    // Perms
    public let canPublish: Bool
    public let canPublishData: Bool
    public let canPublishSources: Set<Track.Source>
    public let canSubscribe: Bool

    public init(delegate: RoomDelegate? = nil,
                url: String? = nil,
                token: String? = nil,
                enableMicrophone: Bool = false,
                encryptionOptions: EncryptionOptions? = nil,
                canPublish: Bool = false,
                canPublishData: Bool = false,
                canPublishSources: Set<Track.Source> = [],
                canSubscribe: Bool = false)
    {
        self.delegate = delegate
        self.url = url
        self.token = token
        self.enableMicrophone = enableMicrophone
        self.encryptionOptions = encryptionOptions
        self.canPublish = canPublish
        self.canPublishData = canPublishData
        self.canPublishSources = canPublishSources
        self.canSubscribe = canSubscribe
    }
}

public extension LKTestCase {
    func readEnvironmentString(for key: String, defaultValue: String) -> String {
        if let string = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            return string
        }

        return defaultValue
    }

    func liveKitServerUrl() -> String {
        readEnvironmentString(for: "LIVEKIT_TESTING_URL", defaultValue: "ws://localhost:7880")
    }

    // swiftlint:disable:next function_parameter_count
    func liveKitServerToken(for room: String,
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

    // Set up variable number of Rooms
    // swiftlint:disable:next function_body_length
    func withRooms(_ options: [RoomTestingOptions] = [],
                   _ block: @escaping ([Room]) async throws -> Void) async throws
    {
        let roomName = UUID().uuidString
        let sharedKey = UUID().uuidString

        let rooms = try options.enumerated().map {
            // Connect options
            let connectOptions = ConnectOptions(enableMicrophone: $0.element.enableMicrophone)

            // Room options
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
                    XCTAssert(element.room.localParticipant.identity != nil, "LocalParticipant.identity is nil")
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

        // Logic to wait other participants to join
        if rooms.count >= 2 {
            // Keep a list of all participant identities
            let allIdentities = rooms.map(\.identity)

            let expectationAndWatches = rooms.map { room, identity, _, _ in
                // Create an Expectation
                let expectation = self.expectation(description: "Wait for other participants to join")
                expectation.assertForOverFulfill = false

                let exceptSelfIdentity = allIdentities.filter { $0 != identity }
                print("Will wait for remote participants: \(exceptSelfIdentity)")

                // Watch Room
                let watch = room.objectWillChange.sink { _ in
                    let remoteIdentities = room.remoteParticipants.map(\.key.stringValue)
                    if remoteIdentities.hasSameElements(as: exceptSelfIdentity) {
                        expectation.fulfill()
                    }
                }

                return (expectation: expectation, watch: watch)
            }

            // Wait for all expectations
            let allExpectations = expectationAndWatches.map(\.expectation)
            await fulfillment(of: allExpectations, timeout: 30)

            // Cancel all watch
            for element in expectationAndWatches {
                element.watch.cancel()
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

public extension Array where Element: Comparable {
    func hasSameElements(as other: [Element]) -> Bool {
        count == other.count && sorted() == other.sorted()
    }
}

public extension Room {
    func createWatcher<T>() -> RoomWatcher<T> {
        let result = RoomWatcher<T>(id: "Room watcher for \(String(describing: sid))")
        add(delegate: result)
        return result
    }
}

public final class RoomWatcher<T: Decodable & Sendable>: RoomDelegate, Sendable {
    public let id: String
    public let didReceiveDataCompleters = CompleterMapActor<T>(label: "Data receive completer", defaultTimeout: 15)

    // MARK: - Private

    private struct State {}

    private let _state = StateSync(State())

    public init(id: String) {
        self.id = id
    }

    // MARK: - Delegates

    public func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType _: EncryptionType) {
        // print("didReceiveData: \(data) for topic: \(topic)")
        Task {
            do {
                let payload = try JSONDecoder().decode(T.self, from: data)
                await didReceiveDataCompleters.resume(returning: payload, for: topic)
            } catch {
                await didReceiveDataCompleters.resume(throwing: LiveKitError(.invalidState), for: topic)
            }
        }
    }
}
