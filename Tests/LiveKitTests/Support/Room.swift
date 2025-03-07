/*
 * Copyright 2025 LiveKit
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
import XCTest

struct RoomTestingOptions {
    let delegate: RoomDelegate?
    let canPublish: Bool
    let canPublishData: Bool
    let canPublishSources: Set<Track.Source>
    let canSubscribe: Bool

    init(delegate: RoomDelegate? = nil,
         canPublish: Bool = false,
         canPublishData: Bool = false,
         canPublishSources: Set<Track.Source> = [],
         canSubscribe: Bool = false)
    {
        self.delegate = delegate
        self.canPublish = canPublish
        self.canPublishData = canPublishData
        self.canPublishSources = canPublishSources
        self.canSubscribe = canSubscribe
    }
}

extension LKTestCase {
    private func readEnvironmentString(for key: String, defaultValue: String) -> String {
        if let string = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            return string
        }

        return defaultValue
    }

    func liveKitServerUrl() -> String {
        readEnvironmentString(for: "LIVEKIT_TESTING_URL", defaultValue: "ws://localhost:7880")
    }

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

        tokenGenerator.videoGrant = VideoGrant(room: room,
                                               roomJoin: true,
                                               canPublish: canPublish,
                                               canSubscribe: canSubscribe,
                                               canPublishData: canPublishData,
                                               canPublishSources: canPublishSources.map(String.init))
        return try tokenGenerator.sign()
    }

    // Set up variable number of Rooms
    func withRooms(_ options: [RoomTestingOptions] = [],
                   sharedKey: String = UUID().uuidString,
                   _ block: @escaping ([Room]) async throws -> Void) async throws
    {
        let e2eeOptions = E2EEOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: sharedKey))

        // Turn on stats
        let roomOptions = RoomOptions(e2eeOptions: e2eeOptions, reportRemoteTrackStatistics: true)

        let url = liveKitServerUrl()
        print("url: \(url)")

        let roomName = UUID().uuidString

        let rooms = try options.enumerated().map {
            // Use shared RoomOptions
            let room = Room(delegate: $0.element.delegate, roomOptions: roomOptions)
            let identity = "identity-\($0.offset)"
            let token = try liveKitServerToken(for: roomName,
                                               identity: identity,
                                               canPublish: $0.element.canPublish,
                                               canPublishData: $0.element.canPublishData,
                                               canPublishSources: $0.element.canPublishSources,
                                               canSubscribe: $0.element.canSubscribe)
            print("Token: \(token) for room: \(roomName)")

            return (room: room, identity: identity, token: token)
        }

        // Connect all Rooms concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for element in rooms {
                group.addTask {
                    try await element.room.connect(url: url, token: element.token)
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

            let expectationAndWatches = rooms.map { room, identity, _ in
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

extension Array where Element: Comparable {
    func hasSameElements(as other: [Element]) -> Bool {
        count == other.count && sorted() == other.sorted()
    }
}

extension Room {
    func createWatcher<T>() -> RoomWatcher<T> {
        let result = RoomWatcher<T>(id: "Room watcher for \(String(describing: sid))")
        add(delegate: result)
        return result
    }
}

class RoomWatcher<T: Decodable>: RoomDelegate {
    public let id: String
    public let didReceiveDataCompleters = CompleterMapActor<T>(label: "Data receive completer", defaultTimeout: 10)

    // MARK: - Private

    private struct State {}

    private let _state = StateSync(State())

    init(id: String) {
        self.id = id
    }

    // MARK: - Delegates

    func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String) {
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
