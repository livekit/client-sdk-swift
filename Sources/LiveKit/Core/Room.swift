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

import Combine
import Foundation

#if canImport(Network)
import Network
#endif

@objcMembers
// swiftlint:disable:next type_body_length
public class Room: NSObject, @unchecked Sendable, ObservableObject, Loggable {
    // MARK: - MulticastDelegate

    public let delegates = MulticastDelegate<RoomDelegate>(label: "RoomDelegate")

    // MARK: - Metrics

    lazy var metricsManager = MetricsManager()

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

    public var serverVersion: String? { _state.serverInfo?.version.nilIfEmpty }

    /// Region code the client is currently connected to.
    public var serverRegion: String? { _state.serverInfo?.region.nilIfEmpty }

    /// Region code the client is currently connected to.
    public var serverNodeId: String? { _state.serverInfo?.nodeID.nilIfEmpty }

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

    public var connectStopwatch: Stopwatch { _state.connectStopwatch }

    // MARK: - Internal

    public var e2eeManager: E2EEManager?

    public lazy var localParticipant: LocalParticipant = .init(room: self)

    let primaryTransportConnectedCompleter = AsyncCompleter<Void>(label: "Primary transport connect", defaultTimeout: .defaultTransportState)
    let publisherTransportConnectedCompleter = AsyncCompleter<Void>(label: "Publisher transport connect", defaultTimeout: .defaultTransportState)

    let activeParticipantCompleters = CompleterMapActor<Void>(label: "Participant active", defaultTimeout: .defaultParticipantActiveTimeout)

    let signalClient = SignalClient()

    // MARK: - DataChannels

    lazy var subscriberDataChannel = DataChannelPair(delegate: self)
    lazy var publisherDataChannel = DataChannelPair(delegate: self)

    let incomingStreamManager = IncomingStreamManager()
    lazy var outgoingStreamManager = OutgoingStreamManager { [weak self] packet in
        try await self?.send(dataPacket: packet)
    } encryptionProvider: { [weak self] in
        self?.e2eeManager?.dataChannelEncryptionType ?? .none
    }

    // MARK: - PreConnect

    lazy var preConnectBuffer = PreConnectAudioBuffer(room: self)

    // MARK: - Queue

    var _blockProcessQueue = DispatchQueue(label: "LiveKitSDK.engine.pendingBlocks",
                                           qos: .default)

    var _queuedBlocks = [ConditionalExecutionEntry]()

    // MARK: - RPC

    let rpcState = RpcStateManager()

    // MARK: - State

    struct State: Equatable, Sendable {
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

        var serverInfo: Livekit_ServerInfo?

        // Engine
        var providedUrl: URL?
        var connectedUrl: URL?
        var token: String?
        var preparedRegion: RegionInfo?

        // preferred reconnect mode which will be used only for next attempt
        var nextReconnectMode: ReconnectMode?
        var isReconnectingWithMode: ReconnectMode?
        var connectionState: ConnectionState = .disconnected
        var reconnectTask: AnyTaskCancellable?
        var disconnectError: LiveKitError?
        var connectStopwatch = Stopwatch(label: "connect")
        var hasPublished: Bool = false

        var publisher: Transport?
        var subscriber: Transport?
        var isSubscriberPrimary: Bool = false
        var isSinglePeerConnection: Bool = false

        /// The transport used for receiving remote tracks and server-opened data channels.
        /// In single PC mode this is the publisher; in dual PC mode this is the subscriber.
        var receiveTransport: Transport? {
            isSinglePeerConnection ? publisher : subscriber
        }

        // Agents
        var transcriptionReceivedTimes: [String: Date] = [:]

        @discardableResult
        mutating func updateRemoteParticipant(info: Livekit_ParticipantInfo, room: Room) -> RemoteParticipant {
            let identity = Participant.Identity(from: info.identity)
            // Check if RemoteParticipant with same identity exists...
            if let participant = remoteParticipants[identity] { return participant }
            // Create new RemoteParticipant...
            let participant = RemoteParticipant(info: info, room: room, connectionState: connectionState)
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

    // MARK: - Region

    let _regionManager = StateSync<RegionManager?>(nil)

    // MARK: Objective-C Support

    override public convenience init() {
        self.init(delegate: nil,
                  connectOptions: ConnectOptions(),
                  roomOptions: RoomOptions())
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public init(delegate: RoomDelegate? = nil,
                connectOptions: ConnectOptions? = nil,
                roomOptions: RoomOptions? = nil)
    {
        // Ensure manager shared objects are instantiated
        DeviceManager.prepare()
        AudioManager.prepare()

        _state = StateSync(State(connectOptions: connectOptions ?? ConnectOptions(),
                                 roomOptions: roomOptions ?? RoomOptions()))

        super.init()
        // log sdk & os versions
        log("sdk: \(LiveKitSDK.version), ffi: \(LiveKitSDK.ffiVersion), os: \(String(describing: Utils.os()))(\(Utils.osVersionString())), modelId: \(String(describing: Utils.modelIdentifier() ?? "unknown"))")

        signalClient._delegate.set(delegate: self)

        log()

        if let delegate {
            log("delegate: \(String(describing: delegate))")
            delegates.add(delegate: delegate)
        }

        // listen to app states
        Task { @MainActor in
            AppStateListener.shared.delegates.add(delegate: self)
        }

        Task {
            await metricsManager.register(room: self)
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

            if newState.connectionState == .reconnecting, newState.isReconnectingWithMode == nil {
                log("reconnectMode should not be .none", .error)
            }

            if (newState.connectionState != oldState.connectionState) || (newState.isReconnectingWithMode != oldState.isReconnectingWithMode) {
                log("connectionState: \(oldState.connectionState) -> \(newState.connectionState), reconnectMode: \(String(describing: newState.isReconnectingWithMode))")
            }

            engine(self, didMutateState: newState, oldState: oldState)

            // execution control
            _blockProcessQueue.async { [weak self] in
                guard let self, !self._queuedBlocks.isEmpty else { return }

                log("[execution control] processing pending entries (\(_queuedBlocks.count))...")

                _queuedBlocks.removeAll { entry in
                    // return and remove this entry if matches remove condition
                    guard !entry.removeCondition(newState, oldState) else { return true }
                    // return but don't remove this entry if doesn't match execute condition
                    guard entry.executeCondition(newState, oldState) else { return false }

                    self.log("[execution control] condition matching block...")
                    entry.block()
                    // remove this entry
                    return true
                }
            }

            // Notify Room when state mutates
            Task { @MainActor in
                self.objectWillChange.send()
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func connect(url urlString: String,
                        token: String,
                        connectOptions: ConnectOptions? = nil,
                        roomOptions: RoomOptions? = nil) async throws
    {
        guard let providedUrl = URL(string: urlString), providedUrl.isValidForConnect else {
            log("URL parse failed", .error)
            throw LiveKitError(.failedToParseUrl)
        }

        log("Connecting to room...", .info)

        var state = _state.copy()

        // update options if specified
        if let roomOptions, roomOptions != state.roomOptions {
            state = _state.mutate {
                $0.roomOptions = roomOptions
                return $0
            }
        }

        // update options if specified
        if let connectOptions, connectOptions != _state.connectOptions {
            _state.mutate { $0.connectOptions = connectOptions }
        }

        let preparedRegion = consumePreparedRegion(for: providedUrl)

        await cleanUp()

        try Task.checkCancellation()

        // enable E2EE
        if let e2eeOptions = state.roomOptions.e2eeOptions {
            e2eeManager = E2EEManager(e2eeOptions: e2eeOptions)
            e2eeManager!.setup(room: self)
        } else if let encryptionOptions = state.roomOptions.encryptionOptions {
            e2eeManager = E2EEManager(options: encryptionOptions)
            e2eeManager!.setup(room: self)

            subscriberDataChannel.e2eeManager = e2eeManager
            publisherDataChannel.e2eeManager = e2eeManager
        } else {
            e2eeManager = nil

            subscriberDataChannel.e2eeManager = nil
            publisherDataChannel.e2eeManager = nil
        }

        _state.mutate {
            $0.providedUrl = providedUrl
            $0.token = token
            $0.connectionState = .connecting
        }

        var nextUrl = providedUrl
        var nextRegion: RegionInfo?
        let regionManager = await regionManager(for: providedUrl)

        if providedUrl.isCloud {
            if let regionManager {
                await regionManager.resetAttempts(onlyIfExhausted: true)

                if let preparedRegion {
                    nextUrl = preparedRegion.url
                    nextRegion = preparedRegion
                } else if await regionManager.shouldRequestSettings() {
                    await regionManager.prepareSettingsFetch(token: token)
                }
            }
        }

        // Concurrent mic publish mode
        let enableMicrophone = _state.connectOptions.enableMicrophone
        log("Concurrent enable microphone mode: \(enableMicrophone)")

        let createMicrophoneTrackTask: Task<LocalTrack, any Error>? = if let recorder = preConnectBuffer.recorder, recorder.isRecording {
            Task {
                recorder.track
            }
        } else if enableMicrophone {
            Task {
                let localTrack = LocalAudioTrack.createTrack(options: _state.roomOptions.defaultAudioCaptureOptions,
                                                             reportStatistics: _state.roomOptions.reportRemoteTrackStatistics)
                // Initializes AudioDeviceModule's recording
                try await localTrack.start()
                return localTrack
            }
        } else {
            nil
        }

        do {
            let finalUrl: URL
            if providedUrl.isCloud {
                guard let regionManager else {
                    throw LiveKitError(.onlyForCloud)
                }

                finalUrl = try await connectWithCloudRegionFailover(regionManager: regionManager,
                                                                    initialUrl: nextUrl,
                                                                    initialRegion: nextRegion,
                                                                    token: token)
            } else {
                try await fullConnectSequence(nextUrl, token)
                finalUrl = nextUrl
            }

            // Connect sequence successful
            log("Connect sequence completed")
            // Final check if cancelled, don't fire connected events
            try Task.checkCancellation()

            _state.mutate {
                $0.connectedUrl = finalUrl
                $0.connectionState = .connected
            }
            // Publish mic if mic task was created
            if let createMicrophoneTrackTask, !createMicrophoneTrackTask.isCancelled {
                let track = try await createMicrophoneTrackTask.value
                try await localParticipant._publish(track: track, options: _state.roomOptions.defaultAudioPublishOptions.withPreconnect(preConnectBuffer.recorder?.isRecording ?? false))
            }
        } catch {
            log("Failed to resolve a region or connect: \(error)")
            // Stop the track if it was created but not published
            if let createMicrophoneTrackTask, !createMicrophoneTrackTask.isCancelled,
               case let .success(track) = await createMicrophoneTrackTask.result
            {
                try? await track.stop()
            }

            await cleanUp(withError: error)
            throw error // Re-throw the original error
        }

        log("Connected to \(String(describing: self))", .info)
    }

    public func disconnect() async {
        let shouldDisconnect = _state.mutate {
            switch $0.connectionState {
            case .disconnecting, .disconnected:
                return false
            default:
                $0.connectionState = .disconnecting
                return true
            }
        }
        guard shouldDisconnect else { return }

        cancelReconnect()

        do {
            try await signalClient.sendLeave()
        } catch {
            log("Failed to send leave with error: \(error)")
        }

        cancelReconnect()

        await cleanUp()

        cancelReconnect()
    }

    private func cancelReconnect() {
        _state.mutate {
            $0.reconnectTask = nil
        }
    }
}

// MARK: - Internal

extension Room {
    // Resets state of Room
    func cleanUp(withError disconnectError: Error? = nil,
                 isFullReconnect: Bool = false) async
    {
        guard !Task.isCancelled else { return }
        log("withError: \(String(describing: disconnectError)), isFullReconnect: \(isFullReconnect)")

        // Reset completers
        _sidCompleter.reset()
        primaryTransportConnectedCompleter.reset()
        publisherTransportConnectedCompleter.reset()

        await signalClient.cleanUp(withError: disconnectError)
        await cleanUpRTC()
        await cleanUpParticipants(isFullReconnect: isFullReconnect)

        // Cleanup for E2EE
        if let e2eeManager {
            e2eeManager.cleanUp()
        }

        // Reset state
        _state.mutate {
            // if isFullReconnect, keep connection related states
            $0 = isFullReconnect ? State(
                connectOptions: $0.connectOptions,
                roomOptions: $0.roomOptions,
                providedUrl: $0.providedUrl,
                connectedUrl: $0.connectedUrl,
                token: $0.token,
                nextReconnectMode: $0.nextReconnectMode,
                isReconnectingWithMode: $0.isReconnectingWithMode,
                connectionState: $0.connectionState,
                reconnectTask: $0.reconnectTask,
                isSinglePeerConnection: $0.isSinglePeerConnection
            ) : State(
                connectOptions: $0.connectOptions,
                roomOptions: $0.roomOptions,
                connectionState: .disconnected,
                reconnectTask: $0.reconnectTask,
                disconnectError: LiveKitError.from(error: disconnectError)
            )
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
        await withTaskGroup(of: Void.self) { group in
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

public extension Room {
    /// Set this to true to bypass initialization of voice processing.
    @available(*, deprecated, renamed: "AudioManager.shared.isVoiceProcessingBypassed")
    @objc
    static var bypassVoiceProcessing: Bool {
        get { AudioManager.shared.isVoiceProcessingBypassed }
        set { AudioManager.shared.isVoiceProcessingBypassed = newValue }
    }
}

// MARK: - DataChannelDelegate

extension Room: DataChannelDelegate {
    func dataChannel(_: DataChannelPair, didReceiveDataPacket dataPacket: Livekit_DataPacket) {
        switch dataPacket.value {
        case let .speaker(update): engine(self, didUpdateSpeakers: update.speakers)
        case let .user(userPacket): engine(self, didReceiveUserPacket: userPacket, encryptionType: dataPacket.encryptedPacket.encryptionType.toLKType())
        case let .transcription(packet): room(didReceiveTranscriptionPacket: packet)
        case let .rpcResponse(response): room(didReceiveRpcResponse: response)
        case let .rpcAck(ack): room(didReceiveRpcAck: ack)
        case let .rpcRequest(request): room(didReceiveRpcRequest: request, from: dataPacket.participantIdentity)
        case let .streamHeader(header):
            incomingStreamManager.handle(.header(header, dataPacket.participantIdentity, dataPacket.encryptedPacket.encryptionType.toLKType()))
        case let .streamChunk(chunk):
            incomingStreamManager.handle(.chunk(chunk, dataPacket.encryptedPacket.encryptionType.toLKType()))
        case let .streamTrailer(trailer):
            incomingStreamManager.handle(.trailer(trailer, dataPacket.encryptedPacket.encryptionType.toLKType()))
        default: return
        }
    }

    func dataChannel(_: DataChannelPair, didFailToDecryptDataPacket _: Livekit_DataPacket, error: LiveKitError) {
        delegates.notify {
            $0.room?(self, didFailToDecryptDataWithEror: error)
        }
    }
}
