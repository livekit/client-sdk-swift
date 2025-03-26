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

import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

actor SignalClient: Loggable {
    // MARK: - Types

    typealias AddTrackRequestPopulator<R> = (inout Livekit_AddTrackRequest) throws -> R
    typealias AddTrackResult<R> = (result: R, trackInfo: Livekit_TrackInfo)

    public enum ConnectResponse: Sendable {
        case join(Livekit_JoinResponse)
        case reconnect(Livekit_ReconnectResponse)

        public var rtcIceServers: [LKRTCIceServer] {
            switch self {
            case let .join(response): return response.iceServers.map { $0.toRTCType() }
            case let .reconnect(response): return response.iceServers.map { $0.toRTCType() }
            }
        }

        public var clientConfiguration: Livekit_ClientConfiguration {
            switch self {
            case let .join(response): return response.clientConfiguration
            case let .reconnect(response): return response.clientConfiguration
            }
        }
    }

    // MARK: - Public

    public private(set) var connectionState: ConnectionState = .disconnected {
        didSet {
            guard connectionState != oldValue else { return }
            // connectionState Updated...
            log("\(oldValue) -> \(connectionState)")

            _delegate.notifyDetached { await $0.signalClient(self, didUpdateConnectionState: self.connectionState, oldState: oldValue, disconnectError: self.disconnectError) }
        }
    }

    public private(set) var disconnectError: LiveKitError?

    // MARK: - Private

    let _delegate = AsyncSerialDelegate<SignalClientDelegate>()
    private let _queue = DispatchQueue(label: "LiveKitSDK.signalClient", qos: .default)

    // Queue to store requests while reconnecting
    private lazy var _requestQueue = QueueActor<Livekit_SignalRequest>(onProcess: { [weak self] request in
        guard let self else { return }

        do {
            // Prepare request data...
            guard let data = try? request.serializedData() else {
                self.log("Could not serialize request data", .error)
                throw LiveKitError(.failedToConvertData, message: "Failed to convert data")
            }

            let webSocket = try await self.requireWebSocket()
            try await webSocket.send(data: data)

        } catch {
            self.log("Failed to send queued request \(request) with error: \(error)", .warning)
        }
    })

    private lazy var _responseQueue = QueueActor<Livekit_SignalResponse>(onProcess: { [weak self] response in
        guard let self else { return }

        await self._process(signalResponse: response)
    })

    private var _webSocket: WebSocket?
    private var _messageLoopTask: Task<Void, Never>?
    private var _lastJoinResponse: Livekit_JoinResponse?

    private let _connectResponseCompleter = AsyncCompleter<ConnectResponse>(label: "Join response", defaultTimeout: .defaultJoinResponse)
    private let _addTrackCompleters = CompleterMapActor<Livekit_TrackInfo>(label: "Completers for add track", defaultTimeout: .defaultPublish)

    private var _pingIntervalTimer = AsyncTimer(interval: 1)
    private var _pingTimeoutTimer = AsyncTimer(interval: 1)

    init() {
        log()
    }

    deinit {
        log(nil, .trace)
    }

    @discardableResult
    func connect(_ url: URL,
                 _ token: String,
                 connectOptions: ConnectOptions? = nil,
                 reconnectMode: ReconnectMode? = nil,
                 participantSid: Participant.Sid? = nil,
                 adaptiveStream: Bool) async throws -> ConnectResponse
    {
        await cleanUp()

        if let reconnectMode {
            log("[Connect] mode: \(String(describing: reconnectMode))")
        }

        let url = try Utils.buildUrl(url,
                                     token,
                                     connectOptions: connectOptions,
                                     reconnectMode: reconnectMode,
                                     participantSid: participantSid,
                                     adaptiveStream: adaptiveStream)

        if reconnectMode != nil {
            log("[Connect] with url: \(url)")
        } else {
            log("Connecting with url: \(url)")
        }

        connectionState = (reconnectMode != nil ? .reconnecting : .connecting)

        do {
            let socket = try await WebSocket(url: url, connectOptions: connectOptions)

            _messageLoopTask = Task.detached {
                self.log("Did enter WebSocket message loop...")
                do {
                    for try await message in socket {
                        await self._onWebSocketMessage(message: message)
                    }
                } catch {
                    await self.cleanUp(withError: error)
                }
            }

            let connectResponse = try await _connectResponseCompleter.wait()
            // Check cancellation after received join response
            try Task.checkCancellation()

            // Successfully connected
            _webSocket = socket
            connectionState = .connected

            return connectResponse
        } catch {
            // Skip validation if user cancelled
            if error is CancellationError {
                await cleanUp(withError: error)
                throw error
            }

            // Skip validation if reconnect mode
            if reconnectMode != nil {
                await cleanUp(withError: error)
                throw error
            }

            await cleanUp(withError: error)

            // Validate...
            let validateUrl = try Utils.buildUrl(url,
                                                 token,
                                                 connectOptions: connectOptions,
                                                 participantSid: participantSid,
                                                 adaptiveStream: adaptiveStream,
                                                 validate: true)

            log("Validating with url: \(validateUrl)...")
            let validationResponse = try await HTTP.requestString(from: validateUrl)
            log("Validate response: \(validationResponse)")
            // re-throw with validation response
            throw LiveKitError(.network, message: "Validation response: \"\(validationResponse)\"")
        }
    }

    func cleanUp(withError disconnectError: Error? = nil) async {
        log("withError: \(String(describing: disconnectError))")

        _pingIntervalTimer.cancel()
        _pingTimeoutTimer.cancel()

        _messageLoopTask?.cancel()
        _messageLoopTask = nil

        _webSocket?.close()
        _webSocket = nil

        _connectResponseCompleter.reset()
        _lastJoinResponse = nil

        await _addTrackCompleters.reset()
        await _requestQueue.clear()
        await _responseQueue.clear()

        self.disconnectError = LiveKitError.from(error: disconnectError)
        connectionState = .disconnected
    }
}

// MARK: - Private

private extension SignalClient {
    // Send request or enqueue while reconnecting
    func _sendRequest(_ request: Livekit_SignalRequest) async throws {
        guard connectionState != .disconnected else {
            log("connectionState is .disconnected", .error)
            throw LiveKitError(.invalidState, message: "connectionState is .disconnected")
        }

        await _requestQueue.processIfResumed(request, elseEnqueue: request.canBeQueued())
    }

    func _onWebSocketMessage(message: URLSessionWebSocketTask.Message) async {
        let response: Livekit_SignalResponse? = {
            switch message {
            case let .data(data): return try? Livekit_SignalResponse(serializedData: data)
            case let .string(string): return try? Livekit_SignalResponse(jsonString: string)
            default: return nil
            }
        }()

        guard let response else {
            log("Failed to decode SignalResponse", .warning)
            return
        }

        Task.detached {
            let alwaysProcess: Bool = {
                switch response.message {
                case .join, .reconnect, .leave: return true
                default: return false
                }
            }()
            // Always process join or reconnect messages even if suspended...
            await self._responseQueue.processIfResumed(response, or: alwaysProcess)
        }
    }

    func _process(signalResponse: Livekit_SignalResponse) async {
        guard connectionState != .disconnected else {
            log("connectionState is .disconnected", .error)
            return
        }

        guard let message = signalResponse.message else {
            log("Failed to decode SignalResponse", .warning)
            return
        }

        switch message {
        case let .join(joinResponse):
            _lastJoinResponse = joinResponse
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveConnectResponse: .join(joinResponse)) }
            _connectResponseCompleter.resume(returning: .join(joinResponse))
            await _restartPingTimer()

        case let .reconnect(response):
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveConnectResponse: .reconnect(response)) }
            _connectResponseCompleter.resume(returning: .reconnect(response))
            await _restartPingTimer()

        case let .answer(sd):
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveAnswer: sd.toRTCType()) }

        case let .offer(sd):
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveOffer: sd.toRTCType()) }

        case let .trickle(trickle):
            guard let rtcCandidate = try? RTC.createIceCandidate(fromJsonString: trickle.candidateInit) else {
                return
            }

            _delegate.notifyDetached { await $0.signalClient(self, didReceiveIceCandidate: rtcCandidate.toLKType(), target: trickle.target) }

        case let .update(update):
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateParticipants: update.participants) }

        case let .roomUpdate(update):
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateRoom: update.room) }

        case let .trackPublished(trackPublished):
            log("[publish] resolving completer for cid: \(trackPublished.cid)")
            // Complete
            await _addTrackCompleters.resume(returning: trackPublished.track, for: trackPublished.cid)

        case let .trackUnpublished(trackUnpublished):
            _delegate.notifyDetached { await $0.signalClient(self, didUnpublishLocalTrack: trackUnpublished) }

        case let .speakersChanged(speakers):
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateSpeakers: speakers.speakers) }

        case let .connectionQuality(quality):
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateConnectionQuality: quality.updates) }

        case let .mute(mute):
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateRemoteMute: Track.Sid(from: mute.sid), muted: mute.muted) }

        case let .leave(leave):
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveLeave: leave.canReconnect, reason: leave.reason) }

        case let .streamStateUpdate(states):
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateTrackStreamStates: states.streamStates) }

        case let .subscribedQualityUpdate(update):
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateSubscribedCodecs: update.subscribedCodecs,
                                                             qualities: update.subscribedQualities,
                                                             forTrackSid: update.trackSid) }

        case let .subscriptionPermissionUpdate(permissionUpdate):
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateSubscriptionPermission: permissionUpdate) }

        case let .refreshToken(token):
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateToken: token) }

        case let .pong(r):
            await _onReceivedPong(r)

        case .pongResp:
            log("Received pongResp message")

        case .subscriptionResponse:
            log("Received subscriptionResponse message")

        case .requestResponse:
            log("Received requestResponse message")

        case let .trackSubscribed(trackSubscribed):
            _delegate.notifyDetached { await $0.signalClient(self, didSubscribeTrack: Track.Sid(from: trackSubscribed.trackSid)) }
        }
    }
}

// MARK: - Internal

extension SignalClient {
    func resumeQueues() async {
        await _responseQueue.resume()
        await _requestQueue.resume()
    }
}

// MARK: - Send methods

extension SignalClient {
    func send(offer: LKRTCSessionDescription) async throws {
        let r = Livekit_SignalRequest.with {
            $0.offer = offer.toPBType()
        }

        try await _sendRequest(r)
    }

    func send(answer: LKRTCSessionDescription) async throws {
        let r = Livekit_SignalRequest.with {
            $0.answer = answer.toPBType()
        }

        try await _sendRequest(r)
    }

    func sendCandidate(candidate: IceCandidate, target: Livekit_SignalTarget) async throws {
        let r = try Livekit_SignalRequest.with {
            $0.trickle = try Livekit_TrickleRequest.with {
                $0.target = target
                $0.candidateInit = try candidate.toJsonString()
            }
        }

        try await _sendRequest(r)
    }

    func sendMuteTrack(trackSid: Track.Sid, muted: Bool) async throws {
        let r = Livekit_SignalRequest.with {
            $0.mute = Livekit_MuteTrackRequest.with {
                $0.sid = trackSid.stringValue
                $0.muted = muted
            }
        }

        try await _sendRequest(r)
    }

    func sendAddTrack<R>(cid: String,
                         name: String,
                         type: Livekit_TrackType,
                         source: Livekit_TrackSource = .unknown,
                         encryption: Livekit_Encryption.TypeEnum = .none,
                         _ populator: AddTrackRequestPopulator<R>) async throws -> AddTrackResult<R>
    {
        var addTrackRequest = Livekit_AddTrackRequest.with {
            $0.cid = cid
            $0.name = name
            $0.type = type
            $0.source = source
            $0.encryption = encryption
        }

        let populateResult = try populator(&addTrackRequest)

        let request = Livekit_SignalRequest.with {
            $0.addTrack = addTrackRequest
        }

        // Get completer for this add track request...
        let completer = await _addTrackCompleters.completer(for: cid)

        // Send the request to server...
        try await _sendRequest(request)

        // Wait for the trackInfo...
        let trackInfo = try await completer.wait()

        return AddTrackResult(result: populateResult, trackInfo: trackInfo)
    }

    func sendUpdateTrackSettings(trackSid: Track.Sid, settings: TrackSettings) async throws {
        let r = Livekit_SignalRequest.with {
            $0.trackSetting = Livekit_UpdateTrackSettings.with {
                $0.trackSids = [trackSid.stringValue]
                $0.disabled = !settings.isEnabled
                $0.width = UInt32(settings.dimensions.width)
                $0.height = UInt32(settings.dimensions.height)
                $0.quality = settings.videoQuality.toPBType()
                $0.fps = UInt32(settings.preferredFPS)
            }
        }

        try await _sendRequest(r)
    }

    func sendUpdateVideoLayers(trackSid: Track.Sid, layers: [Livekit_VideoLayer]) async throws {
        let r = Livekit_SignalRequest.with {
            $0.updateLayers = Livekit_UpdateVideoLayers.with {
                $0.trackSid = trackSid.stringValue
                $0.layers = layers
            }
        }

        try await _sendRequest(r)
    }

    func sendUpdateSubscription(participantSid: Participant.Sid,
                                trackSid: Track.Sid,
                                isSubscribed: Bool) async throws
    {
        let p = Livekit_ParticipantTracks.with {
            $0.participantSid = participantSid.stringValue
            $0.trackSids = [trackSid.stringValue]
        }

        let r = Livekit_SignalRequest.with {
            $0.subscription = Livekit_UpdateSubscription.with {
                $0.trackSids = [trackSid.stringValue]
                $0.participantTracks = [p]
                $0.subscribe = isSubscribed
            }
        }

        try await _sendRequest(r)
    }

    func sendUpdateSubscriptionPermission(allParticipants: Bool,
                                          trackPermissions: [ParticipantTrackPermission]) async throws
    {
        let r = Livekit_SignalRequest.with {
            $0.subscriptionPermission = Livekit_SubscriptionPermission.with {
                $0.allParticipants = allParticipants
                $0.trackPermissions = trackPermissions.map { $0.toPBType() }
            }
        }

        try await _sendRequest(r)
    }

    func sendUpdateParticipant(name: String? = nil,
                               metadata: String? = nil,
                               attributes: [String: String]? = nil) async throws
    {
        let r = Livekit_SignalRequest.with {
            $0.updateMetadata = Livekit_UpdateParticipantMetadata.with {
                $0.name = name ?? ""
                $0.metadata = metadata ?? ""
                $0.attributes = attributes ?? [:]
            }
        }

        try await _sendRequest(r)
    }

    func sendUpdateLocalAudioTrack(trackSid: Track.Sid, features: Set<Livekit_AudioTrackFeature>) async throws {
        let r = Livekit_SignalRequest.with {
            $0.updateAudioTrack = Livekit_UpdateLocalAudioTrack.with {
                $0.trackSid = trackSid.stringValue
                $0.features = Array(features)
            }
        }

        try await _sendRequest(r)
    }

    func sendSyncState(answer: Livekit_SessionDescription?,
                       offer: Livekit_SessionDescription?,
                       subscription: Livekit_UpdateSubscription,
                       publishTracks: [Livekit_TrackPublishedResponse]? = nil,
                       dataChannels: [Livekit_DataChannelInfo]? = nil) async throws
    {
        let r = Livekit_SignalRequest.with {
            $0.syncState = Livekit_SyncState.with {
                if let answer {
                    $0.answer = answer
                }
                if let offer {
                    $0.offer = offer
                }
                $0.subscription = subscription
                $0.publishTracks = publishTracks ?? []
                $0.dataChannels = dataChannels ?? []
            }
        }

        try await _sendRequest(r)
    }

    func sendLeave() async throws {
        let r = Livekit_SignalRequest.with {
            $0.leave = Livekit_LeaveRequest.with {
                $0.canReconnect = false
                $0.reason = .clientInitiated
            }
        }

        try await _sendRequest(r)
    }

    func sendSimulate(scenario: SimulateScenario) async throws {
        var shouldDisconnect = false

        let r = Livekit_SignalRequest.with {
            $0.simulate = Livekit_SimulateScenario.with {
                switch scenario {
                case .nodeFailure: $0.nodeFailure = true
                case .migration: $0.migration = true
                case .serverLeave: $0.serverLeave = true
                case let .speakerUpdate(secs): $0.speakerUpdate = Int32(secs)
                case .forceTCP:
                    $0.switchCandidateProtocol = Livekit_CandidateProtocol.tcp
                    shouldDisconnect = true
                case .forceTLS:
                    $0.switchCandidateProtocol = Livekit_CandidateProtocol.tls
                    shouldDisconnect = true
                default: break
                }
            }
        }

        defer {
            if shouldDisconnect {
                Task.detached {
                    await self.cleanUp()
                }
            }
        }

        try await _sendRequest(r)
    }

    private func _sendPing() async throws {
        let r = Livekit_SignalRequest.with {
            $0.ping = Int64(Date().timeIntervalSince1970)
        }

        try await _sendRequest(r)
    }
}

// MARK: - Server ping/pong logic

private extension SignalClient {
    func _onPingIntervalTimer() async throws {
        guard let jr = _lastJoinResponse else { return }
        log("ping/pong sending ping...", .trace)
        try await _sendPing()

        _pingTimeoutTimer.setTimerInterval(TimeInterval(jr.pingTimeout))
        _pingTimeoutTimer.setTimerBlock { [weak self] in
            guard let self else { return }
            self.log("ping/pong timed out", .error)
            await self.cleanUp(withError: LiveKitError(.serverPingTimedOut))
        }

        _pingTimeoutTimer.startIfStopped()
    }

    func _onReceivedPong(_: Int64) async {
        log("ping/pong received pong from server", .trace)
        // Clear timeout timer
        _pingTimeoutTimer.cancel()
    }

    func _restartPingTimer() async {
        // Always cancel first...
        _pingIntervalTimer.cancel()
        _pingTimeoutTimer.cancel()

        // Check previously received joinResponse
        guard let jr = _lastJoinResponse,
              // Check if server supports ping/pong
              jr.pingTimeout > 0,
              jr.pingInterval > 0 else { return }

        log("ping/pong starting with interval: \(jr.pingInterval), timeout: \(jr.pingTimeout)")

        // Update interval...
        _pingIntervalTimer.setTimerInterval(TimeInterval(jr.pingInterval))
        _pingIntervalTimer.setTimerBlock { [weak self] in
            guard let self else { return }
            try await self._onPingIntervalTimer()
        }
        _pingIntervalTimer.restart()
    }
}

extension Livekit_SignalRequest {
    func canBeQueued() -> Bool {
        switch message {
        case .syncState, .trickle, .offer, .answer, .simulate, .leave: return false
        default: return true
        }
    }
}

private extension SignalClient {
    func requireWebSocket() async throws -> WebSocket {
        guard let result = _webSocket else {
            log("WebSocket is nil", .error)
            throw LiveKitError(.invalidState, message: "WebSocket is nil")
        }

        return result
    }
}
