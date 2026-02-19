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
