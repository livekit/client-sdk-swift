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

// swiftlint:disable file_length

internal import LiveKitFFI
internal import LiveKitWebRTC
import Combine
import Foundation

#if canImport(Network)
import Network
#endif

@objcMembers
public class Room: NSObject, @unchecked Sendable, ObservableObject, Loggable {
    // MARK: - MulticastDelegate

    public let delegates = MulticastDelegate<RoomDelegate>(label: "RoomDelegate")

    // MARK: - Public

    /// Server assigned id of the Room.
    public var sid: Sid? { _state.sid }

    /// Server assigned id of the Room. *async* version of ``Room/sid``.
    public func sid() async throws -> Sid {
        try await _sidCompleter.wait()
    }

    public var name: String? { _state.name }

    /// Room's metadata.
    public var metadata: String? { _state.metadata }

    // Native snapshots omit server info; see API_COV.md.
    public var serverVersion: String? { nil }

    /// Region code the client is currently connected to.
    public var serverRegion: String? { nil }

    /// Region code the client is currently connected to.
    public var serverNodeId: String? { nil }

    public var remoteParticipants: [Participant.Identity: RemoteParticipant] { _state.remoteParticipants }

    public var activeSpeakers: [Participant] { _state.activeSpeakers }

    public var creationTime: Date? { _state.creationTime }

    /// If the current room has a participant with `recorder:true` in its JWT grant.
    public var isRecording: Bool { _state.isRecording }

    public var maxParticipants: Int { _state.maxParticipants }

    public var participantCount: Int { _state.numParticipants }

    public var publishersCount: Int { _state.numPublishers }

    /// User-provided URL.
    public var url: String? { _state.providedUrl?.absoluteString }

    /// Actual server URL used for the current connection (may include a regional URL).
    public var connectedUrl: String? { _state.connectedUrl?.absoluteString }

    public var token: String? { _state.token }

    /// Current ``ConnectionState`` of the ``Room``.
    public var connectionState: ConnectionState { _state.connectionState }

    public var disconnectError: LiveKitError? { _state.disconnectError }

    /// Timing data for the most recent connection attempt.
    public var connectSpan: Span? { _state.connectSpan }

    // MARK: - Internal

    /// The E2EE manager for the current connection.
    ///
    /// Derived from ``RoomOptions/e2eeOptions`` or ``RoomOptions/encryptionOptions`` during
    /// ``connect(url:token:connectOptions:roomOptions:)``, carried across reconnects, and
    /// released when the connection ends. Setting it takes effect only while a connection
    /// exists, and lasts until that connection ends.
    public var e2eeManager: E2EEManager? {
        get { nativeE2EE.copy() }
        set { nativeE2EE.mutate { $0 = newValue } }
    }

    /// Enables or disables end-to-end encryption on this Room.
    ///
    /// Requires the Room to have been constructed with ``EncryptionOptions``
    /// (via ``RoomOptions/encryptionOptions``) and to be connected.
    /// Otherwise this is a no-op.
    ///
    /// - Note: Data tracks advertise whether they are encrypted as part of the publication, so
    ///   the setting is captured when this participant publishes its first data track of the
    ///   session and applies to all of them. Toggling after that point affects media and data
    ///   channel payloads only.
    ///
    /// - Parameter enabled: Whether to enable encryption.
    public func setE2EEEnabled(_ enabled: Bool) {
        let options = _state.roomOptions
        guard options.encryptionOptions != nil || options.e2eeOptions != nil,
              nativeRoom.copy() != nil else { return }
        nativeEncryptionRequested.mutate { $0 = !enabled }
        if !enabled {
            log("Dynamic native encryption disable is not exported; encrypted outgoing operations reject this request", .error)
        }
    }

    public lazy var localParticipant: LocalParticipant = .init(room: self)

    let activeParticipantCompleters = CompleterMapActor<Void>(label: "Participant active", defaultTimeout: .defaultParticipantActiveTimeout)

    let nativeDriver = NativeRoomDriver()
    let nativeRoom = StateSync<FfiRoom?>(nil)
    let nativeEncryptionRequested = StateSync(false)
    let nativeE2EE = StateSync<E2EEManager?>(nil)
    let dataStreams = DataStreams()

    func requireNativeRoom(forEncryptedPayload: Bool = false, forMedia: Bool = false) throws -> FfiRoom {
        let options = _state.roomOptions
        let configured = options.encryptionOptions != nil || options.e2eeOptions != nil
        let encryptedOperation = (forMedia && configured) || (forEncryptedPayload && options.encryptionOptions != nil)
        guard !encryptedOperation || !nativeEncryptionRequested.copy() else {
            throw LiveKitError(.invalidState, message: "Dynamic native encryption disable is not exported")
        }
        guard let session = nativeRoom.copy(), connectionState == .connected || connectionState == .reconnecting else {
            throw LiveKitError(.invalidState, message: "Room is not connected")
        }
        return session
    }

    // MARK: - PreConnect

    lazy var preConnectBuffer = PreConnectAudioBuffer(room: self)

    // MARK: - State

    struct State: Equatable {
        // Options
        var connectOptions: ConnectOptions
        var roomOptions: RoomOptions

        var sid: Sid?
        var name: String?
        var metadata: String?

        var remoteParticipants = [Participant.Identity: RemoteParticipant]()
        var activeSpeakers = [Participant]()

        var creationTime: Date?
        var isRecording: Bool = false

        var maxParticipants: Int = 0
        var numParticipants: Int = 0
        var numPublishers: Int = 0

        // Engine
        var providedUrl: URL?
        var connectedUrl: URL?
        var token: String?
        var connectionState: ConnectionState = .disconnected
        var disconnectError: LiveKitError?

        // Timing
        var connectSpan: Span?

        // Server can deliver `sid` / `name` in a later `RoomUpdate` (e.g. when the
        // initial `JoinResponse.room.sid` is empty). Don't overwrite a known value
        // with an empty one, otherwise `Room.sid()` resolves with an empty SID and
        // never updates.
        mutating func apply(roomInfo: NativeRoomInfo) {
            if let roomSid = roomInfo.sid, !roomSid.isEmpty {
                sid = Room.Sid(from: roomSid)
            }
            if !roomInfo.name.isEmpty {
                name = roomInfo.name
            }

            metadata = roomInfo.metadata
            isRecording = roomInfo.activeRecording
            numParticipants = Int(roomInfo.numParticipants)
            numPublishers = Int(roomInfo.numPublishers)

            if roomInfo.maxParticipants != 0 {
                maxParticipants = Int(roomInfo.maxParticipants)
            }

            if roomInfo.creationTime != 0 {
                creationTime = Date(timeIntervalSince1970: TimeInterval(Double(roomInfo.creationTime) / 1000))
            }
        }

        @discardableResult
        mutating func updateRemoteParticipant(info: NativeParticipant, publications: [NativeTrackPublication], room: Room) -> RemoteParticipant {
            let identity = Participant.Identity(from: info.identity)
            // Check if RemoteParticipant with same identity exists...
            if let participant = remoteParticipants[identity] { return participant }
            // Create new RemoteParticipant...
            let participant = RemoteParticipant(info: info, publications: publications, room: room, connectionState: connectionState)
            remoteParticipants[identity] = participant
            return participant
        }

        // Find RemoteParticipant by Sid
        func remoteParticipant(forSid sid: Participant.Sid) -> RemoteParticipant? {
            remoteParticipants.values.first(where: { $0.sid == sid })
        }
    }

    let _state: StateSync<State>

    private let _sidCompleter = AsyncCompleter<Sid>(label: "sid", defaultTimeout: .resolveSid)

    // MARK: Objective-C Support

    override public convenience init() {
        self.init(delegate: nil,
                  connectOptions: ConnectOptions(),
                  roomOptions: RoomOptions())
    }

    public init(delegate: RoomDelegate? = nil,
                connectOptions: ConnectOptions? = nil,
                roomOptions: RoomOptions? = nil)
    {
        _state = StateSync(State(connectOptions: connectOptions ?? ConnectOptions(),
                                 roomOptions: roomOptions ?? RoomOptions()))

        super.init()
        _ = localParticipant

        dataStreams.attach(room: self)

        // log sdk & os versions
        log("sdk: \(LiveKitSDK.version), ffi: \(LiveKitSDK.ffiVersion), os: \(String(describing: Utils.os()))(\(Utils.osVersionString())), modelId: \(String(describing: Utils.modelIdentifier() ?? "unknown"))")

        log()

        if let delegate {
            log("delegate: \(String(describing: delegate))")
            delegates.add(delegate: delegate)
        }

        // listen to app states
        Task { @MainActor in
            AppStateListener.shared.delegates.add(delegate: self)
        }

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in
            guard let self else { return }

            // sid updated
            if let sid = newState.sid, sid != oldState.sid {
                // Resolve sid
                _sidCompleter.resume(returning: sid)
            }

            if case .connected = newState.connectionState {
                // metadata updated
                if let metadata = newState.metadata, metadata != oldState.metadata,
                   // don't notify if empty string (first time only)
                   oldState.metadata == nil ? !metadata.isEmpty : true
                {
                    delegates.notify(label: { "room.didUpdate metadata: \(metadata)" }) {
                        $0.room?(self, didUpdateMetadata: metadata)
                    }
                }

                // isRecording updated
                if newState.isRecording != oldState.isRecording {
                    delegates.notify(label: { "room.didUpdate isRecording: \(newState.isRecording)" }) {
                        $0.room?(self, didUpdateIsRecording: newState.isRecording)
                    }
                }
            }

            if newState.connectionState != oldState.connectionState {
                log("connectionState: \(oldState.connectionState) -> \(newState.connectionState)")
            }

            engine(self, didMutateState: newState, oldState: oldState)

            // Notify Room when state mutates
            Task { @MainActor in
                self.objectWillChange.send()
            }
        }
    }

    public func connect(url urlString: String,
                        token: String,
                        connectOptions: ConnectOptions? = nil,
                        roomOptions: RoomOptions? = nil) async throws
    {
        try await nativeDriver.connect(room: self, url: urlString, token: token,
                                       connectOptions: connectOptions, roomOptions: roomOptions)
    }

    public func disconnect() async {
        await nativeDriver.disconnect(room: self)
    }

    deinit {
        let tracks = localParticipant.trackPublications.values.compactMap(\.track)
        Task.detached {
            for track in tracks {
                await track.detachNativeSource()
            }
        }
    }
}

// MARK: - Internal

extension Room {
    @nonobjc func cleanUp(withError disconnectError: Error? = nil) async {
        await nativeDriver.disconnect(room: self, error: disconnectError)
    }

    @nonobjc func resetNativeState(error: Error? = nil) async {
        _sidCompleter.reset(throwing: error)
        await activeParticipantCompleters.reset(throwing: error)
        for publication in localParticipant.trackPublications.values {
            await publication.track?.detachNativeSource()
        }
        await cleanUpParticipants()
        nativeE2EE.mutate { $0 = nil }
        nativeEncryptionRequested.mutate { $0 = false }
        _state.mutate {
            $0 = State(connectOptions: $0.connectOptions, roomOptions: $0.roomOptions,
                       connectionState: .disconnected, disconnectError: LiveKitError.from(error: error))
        }
    }
}

// MARK: - Internal

extension Room {
    func cleanUpParticipants(isFullReconnect: Bool = false, notify _notify: Bool = true) async {
        log("notify: \(_notify)")

        // Stop all local & remote tracks
        var allParticipants: [Participant] = Array(_state.remoteParticipants.values)
        if !isFullReconnect {
            allParticipants.append(localParticipant)
        }

        // Clean up Participants concurrently
        await withTaskGroup { group in
            for participant in allParticipants {
                group.addTask {
                    await participant.cleanUp(notify: _notify)
                }
            }

            await group.waitForAll()
        }

        _state.mutate {
            $0.remoteParticipants = [:]
        }
    }

    func _onParticipantDidDisconnect(identity: Participant.Identity) async throws {
        guard let participant = _state.mutate({ $0.remoteParticipants.removeValue(forKey: identity) }) else {
            throw LiveKitError(.invalidState, message: "Participant not found for \(identity)")
        }

        await participant.cleanUp(notify: true)
    }
}

// MARK: - AppStateDelegate

extension Room: AppStateDelegate {
    func appDidEnterBackground() {
        guard _state.roomOptions.suspendLocalVideoTracksInBackground else { return }

        let cameraVideoTracks = localParticipant.localVideoTracks.filter { $0.source == .camera }

        guard !cameraVideoTracks.isEmpty else { return }

        Task.detached {
            for cameraVideoTrack in cameraVideoTracks {
                do {
                    try await cameraVideoTrack.suspend()
                } catch {
                    self.log("Failed to suspend video track with error: \(error)")
                }
            }
        }
    }

    func appWillEnterForeground() {
        let cameraVideoTracks = localParticipant.localVideoTracks.filter { $0.source == .camera }

        guard !cameraVideoTracks.isEmpty else { return }

        Task.detached {
            for cameraVideoTrack in cameraVideoTracks {
                do {
                    try await cameraVideoTrack.resume()
                } catch {
                    self.log("Failed to resumed video track with error: \(error)")
                }
            }
        }
    }

    func appWillTerminate() {
        // attempt to disconnect if already connected.
        // this is not guranteed since there is no reliable way to detect app termination.
        Task.detached {
            await self.disconnect()
        }
    }

    func appWillSleep() {
        Task.detached {
            await self.disconnect()
        }
    }

    func appDidWake() {}
}

// MARK: - Devices

// swiftformat:disable:next extensionAttributes
public extension Room {
    /// Set this to true to bypass initialization of voice processing.
    @available(*, deprecated, renamed: "AudioManager.shared.isVoiceProcessingBypassed")
    @objc
    static var bypassVoiceProcessing: Bool {
        get { AudioManager.shared.isVoiceProcessingBypassed }
        set { AudioManager.shared.isVoiceProcessingBypassed = newValue }
    }
}
