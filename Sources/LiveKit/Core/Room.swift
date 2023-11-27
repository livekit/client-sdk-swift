/*
 * Copyright 2022 LiveKit
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
import WebRTC
import Promises

#if canImport(Network)
import Network
#endif

@objc
public class Room: NSObject, ObservableObject, Loggable {

    // MARK: - MulticastDelegate

    internal var delegates = MulticastDelegate<RoomDelegateObjC>()

    internal let queue = DispatchQueue(label: "LiveKitSDK.room", qos: .default)

    // MARK: - Public

    @objc
    public var sid: Sid? { _state.sid }

    @objc
    public var name: String? { _state.name }

    /// Room's metadata.
    @objc
    public var metadata: String? { _state.metadata }

    @objc
    public var serverVersion: String? { _state.serverVersion }

    /// Region code the client is currently connected to.
    @objc
    public var serverRegion: String? { _state.serverRegion }

    @objc
    public var localParticipant: LocalParticipant? { _state.localParticipant }

    @objc
    public var remoteParticipants: [Sid: RemoteParticipant] { _state.remoteParticipants }

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
    public var connectionState: ConnectionState { engine._state.connectionState }

    /// Only for Objective-C.
    @objc(connectionState)
    @available(swift, obsoleted: 1.0)
    public var connectionStateObjC: ConnectionStateObjC { engine._state.connectionState.toObjCType() }

    public var connectStopwatch: Stopwatch { engine._state.connectStopwatch }

    // MARK: - Internal

    // Reference to Engine
    internal let engine: Engine

    public var e2eeManager: E2EEManager?

    internal struct State: Equatable {
        var options: RoomOptions

        var sid: String?
        var name: String?
        var metadata: String?
        var serverVersion: String?
        var serverRegion: String?

        var localParticipant: LocalParticipant?
        var remoteParticipants = [Sid: RemoteParticipant]()
        var activeSpeakers = [Participant]()

        var isRecording: Bool = false

        var maxParticipants: Int = 0
        var numParticipants: Int = 0
        var numPublishers: Int = 0

        @discardableResult
        mutating func getOrCreateRemoteParticipant(sid: Sid, info: Livekit_ParticipantInfo? = nil, room: Room) -> RemoteParticipant {

            if let participant = remoteParticipants[sid] {
                return participant
            }

            let participant = RemoteParticipant(sid: sid, info: info, room: room)
            remoteParticipants[sid] = participant
            return participant
        }
    }

    internal var _state: StateSync<State>

    // MARK: Objective-C Support

    @objc
    public convenience override init() {

        self.init(delegate: nil,
                  connectOptions: ConnectOptions(),
                  roomOptions: RoomOptions())
    }

    @objc
    public init(delegate: RoomDelegateObjC? = nil,
                connectOptions: ConnectOptions? = nil,
                roomOptions: RoomOptions? = nil) {

        self._state = StateSync(State(options: roomOptions ?? RoomOptions()))
        self.engine = Engine(connectOptions: connectOptions ?? ConnectOptions())
        super.init()

        log()

        // weak ref
        engine.room = self

        // listen to engine & signalClient
        engine.add(delegate: self)
        engine.signalClient.add(delegate: self)

        if let delegate = delegate {
            log("delegate: \(String(describing: delegate))")
            delegates.add(delegate: delegate)
        }

        // listen to app states
        AppStateListener.shared.add(delegate: self)

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in

            guard let self = self else { return }

            // metadata updated
            if let metadata = newState.metadata, metadata != oldState.metadata,
               // don't notify if empty string (first time only)
               oldState.metadata == nil ? !metadata.isEmpty : true {

                // proceed only if connected...
                self.engine.executeIfConnected { [weak self] in

                    guard let self = self else { return }

                    self.delegates.notify(label: { "room.didUpdate metadata: \(metadata)" }) {
                        $0.room?(self, didUpdate: metadata)
                    }
                }
            }

            // isRecording updated
            if newState.isRecording != oldState.isRecording {
                // proceed only if connected...
                self.engine.executeIfConnected { [weak self] in

                    guard let self = self else { return }

                    self.delegates.notify(label: { "room.didUpdate isRecording: \(newState.isRecording)" }) {
                        $0.room?(self, didUpdate: newState.isRecording)
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

    @discardableResult
    public func connect(_ url: String,
                        _ token: String,
                        connectOptions: ConnectOptions? = nil,
                        roomOptions: RoomOptions? = nil) -> Promise<Room> {

        log("connecting to room...", .info)

        let state = _state.copy()

        guard state.localParticipant == nil else {
            log("localParticipant is not nil", .warning)
            return Promise(EngineError.state(message: "localParticipant is not nil"))
        }

        // update options if specified
        if let roomOptions = roomOptions, roomOptions != state.options {
            _state.mutate { $0.options = roomOptions }
        }

        // enable E2EE
        if roomOptions?.e2eeOptions != nil {
            self.e2eeManager = E2EEManager(e2eeOptions: roomOptions!.e2eeOptions!)
            self.e2eeManager!.setup(room: self)
        }

        // monitor.start(queue: monitorQueue)
        return engine.connect(url, token,
                              connectOptions: connectOptions).then(on: queue) { () -> Room in
                                self.log("connected to \(String(describing: self)) \(String(describing: state.localParticipant))", .info)
                                return self
                              }
    }

    @discardableResult
    public func disconnect() -> Promise<Void> {

        // return if already disconnected state
        if case .disconnected = connectionState { return Promise(()) }

        return engine.signalClient.sendLeave()
            .recover(on: queue) { self.log("Failed to send leave, error: \($0)") }
            .then(on: queue) { [weak self] in
                guard let self = self else { return }
                self.cleanUp(reason: .user)
            }
    }
}

// MARK: - Internal

internal extension Room {

    // Resets state of Room
    @discardableResult
    func cleanUp(reason: DisconnectReason? = nil,
                 isFullReconnect: Bool = false) -> Promise<Void> {

        log("reason: \(String(describing: reason))")

        // start Engine cleanUp sequence

        engine._state.mutate {
            $0.primaryTransportConnectedCompleter.reset()
            $0.publisherTransportConnectedCompleter.reset()

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
                connectionState: .disconnected(reason: reason)
            )
        }

        engine.signalClient.cleanUp(reason: reason)

        return engine.cleanUpRTC().then(on: queue) {
            self.cleanUpParticipants()
        }.then(on: queue) {
            // reset state
            self._state.mutate { $0 = State(options: $0.options) }
        }.catch(on: queue) { error in
            // this should never happen
            self.log("Room cleanUp failed with error: \(error)", .error)
        }
    }
}

// MARK: - Internal

internal extension Room {

    @discardableResult
    func cleanUpParticipants(notify _notify: Bool = true) -> Promise<Void> {

        log("notify: \(_notify)")

        // Stop all local & remote tracks
        let allParticipants = ([[localParticipant],
                                _state.remoteParticipants.map { $0.value }] as [[Participant?]])
            .joined()
            .compactMap { $0 }

        let cleanUpPromises = allParticipants.map { $0.cleanUp(notify: _notify) }

        return cleanUpPromises.all(on: queue).then(on: queue) {
            //
            self._state.mutate {
                $0.localParticipant = nil
                $0.remoteParticipants = [:]
            }
        }
    }

    @discardableResult
    func onParticipantDisconnect(sid: Sid) -> Promise<Void> {

        guard let participant = _state.mutate({ $0.remoteParticipants.removeValue(forKey: sid) }) else {
            return Promise(EngineError.state(message: "Participant not found for \(sid)"))
        }

        return participant.cleanUp(notify: true)
    }
}

// MARK: - Debugging

extension Room {

    @discardableResult
    public func sendSimulate(scenario: SimulateScenario) -> Promise<Void> {
        engine.signalClient.sendSimulate(scenario: scenario)
    }

    public func waitForPrimaryTransportConnect() -> Promise<Bool> {
        engine._state.mutate {
            $0.primaryTransportConnectedCompleter.wait(on: queue, .defaultTransportState, throw: { TransportError.timedOut(message: "primary transport didn't connect") })
        }
    }

    public func waitForPublisherTransportConnect() -> Promise<Bool> {
        engine._state.mutate {
            $0.publisherTransportConnectedCompleter.wait(on: queue, .defaultTransportState, throw: { TransportError.timedOut(message: "publisher transport didn't connect") })
        }
    }
}

// MARK: - Session Migration

internal extension Room {

    func resetTrackSettings() {

        log("resetting track settings...")

        // create an array of RemoteTrackPublication
        let remoteTrackPublications = _state.remoteParticipants.values.map {
            $0._state.tracks.values.compactMap { $0 as? RemoteTrackPublication }
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

        guard let localParticipant = localParticipant else { return }
        let promises = localParticipant.localVideoTracks.filter { $0.source == .camera }.map { $0.suspend() }

        guard !promises.isEmpty else { return }

        promises.all(on: queue).then(on: queue) {
            self.log("suspended all video tracks")
        }
    }

    func appWillEnterForeground() {

        guard let localParticipant = localParticipant else { return }
        let promises = localParticipant.localVideoTracks.filter { $0.source == .camera }.map { $0.resume() }

        guard !promises.isEmpty else { return }

        promises.all(on: queue).then(on: queue) {
            self.log("resumed all video tracks")
        }
    }

    func appWillTerminate() {
        // attempt to disconnect if already connected.
        // this is not guranteed since there is no reliable way to detect app termination.
        disconnect()
    }
}

// MARK: - Devices

extension Room {

    @objc
    public static var audioDeviceModule: RTCAudioDeviceModule {
        Engine.audioDeviceModule
    }

    /// Set this to true to bypass initialization of voice processing.
    /// Must be set before RTCPeerConnectionFactory gets initialized.
    @objc
    public static var bypassVoiceProcessing: Bool {
        get { Engine.bypassVoiceProcessing }
        set { Engine.bypassVoiceProcessing = newValue }
    }
}

// MARK: - Audio Processing

extension Room {

    @objc
    public static var audioProcessingModule: RTCDefaultAudioProcessingModule {
        Engine.audioProcessingModule
    }
}
