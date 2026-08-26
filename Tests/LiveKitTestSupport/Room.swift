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

public struct RoomTestingOptions {
    public let delegate: RoomDelegate?
    public let url: String?
    public let token: String?
    /// Room to join. When `nil`, all rooms in a `withRooms` call share one generated name (so they
    /// meet); set it explicitly (same value across calls) to stage a late joiner into an existing
    /// room.
    public let roomName: String?
    /// Participant identity. When `nil`, defaults to `identity-<index>` within the `withRooms` call.
    public let identity: String?
    public let enableMicrophone: Bool
    /// `withRooms` enables E2EE (with a shared key) by default; set `false` for a plaintext room.
    public let isE2eeEnabled: Bool
    public let encryptionOptions: EncryptionOptions?
    public let singlePeerConnection: Bool

    /// Override the client protocol version advertised to peers. When `nil`, uses the SDK default.
    public let clientProtocol: ClientProtocol?

    // Perms
    public let canPublish: Bool
    public let canPublishData: Bool
    public let canPublishSources: Set<Track.Source>
    public let canSubscribe: Bool
    public let telemetry: TelemetryOptions?

    public init(delegate: RoomDelegate? = nil,
                url: String? = nil,
                token: String? = nil,
                roomName: String? = nil,
                identity: String? = nil,
                enableMicrophone: Bool = false,
                isE2eeEnabled: Bool = true,
                encryptionOptions: EncryptionOptions? = nil,
                singlePeerConnection: Bool = false,
                clientProtocol: ClientProtocol? = nil,
                canPublish: Bool = false,
                canPublishData: Bool = false,
                canPublishSources: Set<Track.Source> = [],
                canSubscribe: Bool = false,
                telemetry: TelemetryOptions? = nil)
    {
        self.delegate = delegate
        self.url = url
        self.token = token
        self.roomName = roomName
        self.identity = identity
        self.enableMicrophone = enableMicrophone
        self.isE2eeEnabled = isE2eeEnabled
        self.encryptionOptions = encryptionOptions
        self.singlePeerConnection = singlePeerConnection
        self.clientProtocol = clientProtocol
        self.canPublish = canPublish
        self.canPublishData = canPublishData
        self.canPublishSources = canPublishSources
        self.canSubscribe = canSubscribe
        self.telemetry = telemetry
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
