/*
 * Copyright 2024 LiveKit
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

#if canImport(Network)
    import Network
#endif

@objc
public class Room: NSObject, ObservableObject, Loggable {
    // MARK: - MulticastDelegate

    public let delegates = MulticastDelegate<RoomDelegate>()

    // MARK: - Public

    @objc
    /// Server assigned id of the Room.
    public var sid: Sid? { _state.sid }

    /// Server assigned id of the Room. *async* version of ``Room/sid``.
    @objc
    public func sid() async throws -> Sid {
        try await _sidCompleter.wait()
    }

    @objc
    public var name: String? { _state.name }

    /// Room's metadata.
    @objc
    public var metadata: String? { _state.metadata }

    @objc
    public var serverVersion: String? { _state.serverInfo?.version.nilIfEmpty }

    /// Region code the client is currently connected to.
    @objc
    public var serverRegion: String? { _state.serverInfo?.region.nilIfEmpty }

    /// Region code the client is currently connected to.
    @objc
    public var serverNodeId: String? { _state.serverInfo?.nodeID.nilIfEmpty }

    @objc
    public var remoteParticipants: [Identity: RemoteParticipant] { _state.remoteParticipants }

    @objc
    public var activeSpeakers: [Participant] { _state.activeSpeakers }

    /// If the current room has a participant with `recorder:true` in its JWT grant.
    @objc
    public var isRecording: Bool { _state.isRecording }

    @objc
    public var maxParticipants: Int { _state.maxParticipants }

    @objc
    public var participantCount: Int { _state.numParticipants }

    @objc
    public var publishersCount: Int { _state.numPublishers }

    // expose engine's vars
    @objc
    public var url: String? { engine._state.url }

    @objc
    public var token: String? { engine._state.token }

    /// Current ``ConnectionState`` of the ``Room``.
    @objc
    public var connectionState: ConnectionState { engine._state.connectionState }

    @objc
    public var disconnectError: LiveKitError? { engine._state.disconnectError }

    public var connectStopwatch: Stopwatch { engine._state.connectStopwatch }

    // MARK: - Internal

    // Reference to Engine
    let engine: Engine

    public var e2eeManager: E2EEManager?

    @objc
    public lazy var localParticipant: LocalParticipant = .init(room: self)

    struct State: Equatable {
        var options: RoomOptions

        var sid: String?
        var name: String?
        var metadata: String?

        var remoteParticipants = [Identity: RemoteParticipant]()
        var activeSpeakers = [Participant]()

        var isRecording: Bool = false

        var maxParticipants: Int = 0
        var numParticipants: Int = 0
        var numPublishers: Int = 0

        var serverInfo: Livekit_ServerInfo?

        @discardableResult
        mutating func updateRemoteParticipant(info: Livekit_ParticipantInfo, room: Room) -> RemoteParticipant {
            // Check if RemoteParticipant with same identity exists...
            if let participant = remoteParticipants[info.identity] { return participant }
            // Create new RemoteParticipant...
            let participant = RemoteParticipant(info: info, room: room)
            remoteParticipants[info.identity] = participant
            return participant
        }

        // Find RemoteParticipant by Sid
        func remoteParticipant(sid: Sid) -> RemoteParticipant? {
            remoteParticipants.values.first(where: { $0.sid == sid })
        }
    }

    var _state: StateSync<State>

    private let _sidCompleter = AsyncCompleter<Sid>(label: "sid", defaultTimeOut: .sid)

    // MARK: Objective-C Support

    @objc
    override public convenience init() {
        self.init(delegate: nil,
                  connectOptions: ConnectOptions(),
                  roomOptions: RoomOptions())
    }

    @objc
    public init(delegate: RoomDelegate? = nil,
                connectOptions: ConnectOptions? = nil,
                roomOptions: RoomOptions? = nil)
    {
        _state = StateSync(State(options: roomOptions ?? RoomOptions()))
        engine = Engine(connectOptions: connectOptions ?? ConnectOptions())
        super.init()

        log()

        // weak ref
        engine._room = self

        // listen to engine & signalClient
        engine.add(delegate: self)
        engine.signalClient.add(delegate: self)

        if let delegate {
            log("delegate: \(String(describing: delegate))")
            delegates.add(delegate: delegate)
        }

        // listen to app states
        AppStateListener.shared.add(delegate: self)

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in

            guard let self else { return }

            // sid updated
            if let sid = newState.sid, sid != oldState.sid {
                // Resolve sid
                self._sidCompleter.resume(returning: sid)
            }

            // metadata updated
            if let metadata = newState.metadata, metadata != oldState.metadata,
               // don't notify if empty string (first time only)
               oldState.metadata == nil ? !metadata.isEmpty : true
            {
                // proceed only if connected...
                self.engine.executeIfConnected { [weak self] in

                    guard let self else { return }

                    self.delegates.notify(label: { "room.didUpdate metadata: \(metadata)" }) {
                        $0.room?(self, didUpdateMetadata: metadata)
                    }
                }
            }

            // isRecording updated
            if newState.isRecording != oldState.isRecording {
                // proceed only if connected...
                self.engine.executeIfConnected { [weak self] in

                    guard let self else { return }

                    self.delegates.notify(label: { "room.didUpdate isRecording: \(newState.isRecording)" }) {
                        $0.room?(self, didUpdateIsRecording: newState.isRecording)
                    }
                }
            }

            // Notify Room when state mutates
            Task.detached { @MainActor in
                self.objectWillChange.send()
            }
        }
    }

    deinit {
        log()
        // cleanup for E2EE
        if self.e2eeManager != nil {
            self.e2eeManager?.cleanUp()
        }
    }

    @objc
    public func connect(url: String,
                        token: String,
                        connectOptions: ConnectOptions? = nil,
                        roomOptions: RoomOptions? = nil) async throws
    {
        log("connecting to room...", .info)

        let state = _state.copy()

        // update options if specified
        if let roomOptions, roomOptions != state.options {
            _state.mutate { $0.options = roomOptions }
        }

        // enable E2EE
        if roomOptions?.e2eeOptions != nil {
            e2eeManager = E2EEManager(e2eeOptions: roomOptions!.e2eeOptions!)
            e2eeManager!.setup(room: self)
        }

        try await engine.connect(url, token, connectOptions: connectOptions)

        log("Connected to \(String(describing: self))", .info)
    }

    @objc
    public func disconnect() async {
        // Return if already disconnected state
        if case .disconnected = connectionState { return }

        do {
            try await engine.signalClient.sendLeave()
        } catch {
            log("Failed to send leave with error: \(error)")
        }

        await cleanUp()
    }
}

// MARK: - Internal

extension Room {
    // Resets state of Room
    func cleanUp(withError disconnectError: Error? = nil,
                 isFullReconnect: Bool = false) async
    {
        log("withError: \(String(describing: disconnectError))")

        // Start Engine cleanUp sequence

        engine.primaryTransportConnectedCompleter.reset()
        engine.publisherTransportConnectedCompleter.reset()

        engine._state.mutate {
            // if isFullReconnect, keep connection related states
            $0 = isFullReconnect ? Engine.State(
                connectOptions: $0.connectOptions,
                url: $0.url,
                token: $0.token,
                nextPreferredReconnectMode: $0.nextPreferredReconnectMode,
                reconnectMode: $0.reconnectMode,
                connectionState: $0.connectionState
            ) : Engine.State(
                connectOptions: $0.connectOptions,
                connectionState: .disconnected,
                disconnectError: LiveKitError.from(error: disconnectError)
            )
        }

        await engine.signalClient.cleanUp(withError: disconnectError)
        await engine.cleanUpRTC()
        await cleanUpParticipants()
        // Reset state
        _state.mutate { $0 = State(options: $0.options) }

        // Reset completers
        _sidCompleter.reset()
    }
}

// MARK: - Internal

extension Room {
    func cleanUpParticipants(notify _notify: Bool = true) async {
        log("notify: \(_notify)")

        // Stop all local & remote tracks
        let allParticipants = ([[localParticipant], Array(_state.remoteParticipants.values)] as [[Participant?]])
            .joined()
            .compactMap { $0 }

        // Clean up Participants concurrently
        await withTaskGroup(of: Void.self) { group in
            for participant in allParticipants {
                group.addTask {
                    await participant.cleanUp(notify: _notify)
                }
            }
        }

        _state.mutate {
            $0.remoteParticipants = [:]
        }
    }

    func _onParticipantDidDisconnect(identity: Identity) async throws {
        guard let participant = _state.mutate({ $0.remoteParticipants.removeValue(forKey: identity) }) else {
            throw LiveKitError(.invalidState, message: "Participant not found for \(identity)")
        }

        await participant.cleanUp(notify: true)
    }
}

// MARK: - Debugging

public extension Room {
    func sendSimulate(scenario: SimulateScenario) async throws {
        try await engine.signalClient.sendSimulate(scenario: scenario)
    }

    func debug_triggerReconnect(reason: StartReconnectReason) async throws {
        try await engine.startReconnect(reason: reason)
    }
}

// MARK: - Session Migration

extension Room {
    func resetTrackSettings() {
        log("resetting track settings...")

        // create an array of RemoteTrackPublication
        let remoteTrackPublications = _state.remoteParticipants.values.map {
            $0._state.trackPublications.values.compactMap { $0 as? RemoteTrackPublication }
        }.joined()

        // reset track settings for all RemoteTrackPublication
        for publication in remoteTrackPublications {
            publication.resetTrackSettings()
        }
    }
}

// MARK: - AppStateDelegate

extension Room: AppStateDelegate {
    func appDidEnterBackground() {
        guard _state.options.suspendLocalVideoTracksInBackground else { return }

        let cameraVideoTracks = localParticipant.localVideoTracks.filter { $0.source == .camera }

        guard !cameraVideoTracks.isEmpty else { return }

        Task {
            for cameraVideoTrack in cameraVideoTracks {
                do {
                    try await cameraVideoTrack.suspend()
                } catch {
                    log("Failed to suspend video track with error: \(error)")
                }
            }
        }
    }

    func appWillEnterForeground() {
        let cameraVideoTracks = localParticipant.localVideoTracks.filter { $0.source == .camera }

        guard !cameraVideoTracks.isEmpty else { return }

        Task {
            for cameraVideoTrack in cameraVideoTracks {
                do {
                    try await cameraVideoTrack.resume()
                } catch {
                    log("Failed to resumed video track with error: \(error)")
                }
            }
        }
    }

    func appWillTerminate() {
        // attempt to disconnect if already connected.
        // this is not guranteed since there is no reliable way to detect app termination.
        Task {
            await disconnect()
        }
    }
}

// MARK: - Devices

public extension Room {
    /// Set this to true to bypass initialization of voice processing.
    /// Must be set before RTCPeerConnectionFactory gets initialized.
    @objc
    static var bypassVoiceProcessing: Bool {
        get { Engine.bypassVoiceProcessing }
        set { Engine.bypassVoiceProcessing = newValue }
    }
}
