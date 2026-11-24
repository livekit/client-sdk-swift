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

import Combine
import Foundation

/// Holds the encryption configuration of a ``Room`` connection.
///
/// - Note: The native session encrypts media and data. This object keeps the public options and the
///   enabled flag; it does not create per-track frame cryptors, so it emits no per-publication
///   `didUpdateE2EEState` callbacks.
@objcMembers
public class E2EEManager: NSObject, @unchecked Sendable, ObservableObject, Loggable {
    // MARK: - Public

    public let e2eeOptions: E2EEOptions?
    public let options: EncryptionOptions?

    public var keyProvider: BaseKeyProvider {
        options?.keyProvider ?? e2eeOptions?.keyProvider ?? BaseKeyProvider()
    }

    public var frameEncryptionType: EncryptionType {
        options?.encryptionType ?? e2eeOptions?.encryptionType ?? .none
    }

    public var isDataChannelEncryptionEnabled: Bool {
        _enabled.copy() && options != nil
    }

    public var dataChannelEncryptionType: EncryptionType {
        guard isDataChannelEncryptionEnabled else { return .none }
        return options?.encryptionType ?? .none
    }

    // MARK: - Private

    private weak var _room: Room?
    private let _enabled = StateSync(true)

    public init(e2eeOptions: E2EEOptions) {
        self.e2eeOptions = e2eeOptions
        options = nil
        super.init()
    }

    public init(options: EncryptionOptions) {
        e2eeOptions = nil
        self.options = options
        super.init()
    }

    public func setup(room: Room) {
        _room = room
        room.add(delegate: self)
    }

    public func enableE2EE(enabled: Bool) {
        _enabled.mutate { $0 = enabled }
    }

    public func cleanUp() {}
}

// ponytail: the native session owns per-track cryptors; these callbacks keep the public conformance.
// swiftformat:disable unusedArguments
extension E2EEManager: RoomDelegate {
    public func room(_: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {}

    public func room(_: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {}

    public func room(_: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {}

    public func room(_: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {}
}

// swiftformat:enable unusedArguments
