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

internal import LiveKitWebRTC

actor SignalClient: Loggable {
    // MARK: - Types

    typealias AddTrackRequestPopulator = @Sendable (inout Livekit_AddTrackRequest) throws -> Void

    enum ConnectResponse: Sendable {
        case join(Livekit_JoinResponse)
        case reconnect(Livekit_ReconnectResponse)

        var rtcIceServers: [LKRTCIceServer] {
            switch self {
            case let .join(response): response.iceServers.map { $0.toRTCType() }
            case let .reconnect(response): response.iceServers.map { $0.toRTCType() }
            }
        }

        var clientConfiguration: Livekit_ClientConfiguration {
            switch self {
            case let .join(response): response.clientConfiguration
            case let .reconnect(response): response.clientConfiguration
            }
        }
    }

    // MARK: - Public

    var connectionState: ConnectionState { _state.connectionState }

    var disconnectError: LiveKitError? { _state.disconnectError }

    // MARK: - Private

    let _delegate = AsyncSerialDelegate<SignalClientDelegate>()
    private let _queue = DispatchQueue(label: "LiveKitSDK.signalClient", qos: .default)

    // Queue to store requests while reconnecting
    private lazy var _requestQueue = QueueActor<Livekit_SignalRequest>(onProcess: { [weak self] request in
        guard let self else { return }

        do {
            // Prepare request data...
            guard let data = try? request.serializedData() else {
                log("Could not serialize request data", .error)
                throw LiveKitError(.failedToConvertData, message: "Failed to convert data")
            }

            let webSocket = try await requireWebSocket()
            try await webSocket.send(data: data)

        } catch {
            log("Failed to send queued request \(request) with error: \(error)", .warning)
        }
    })

    private lazy var _responseQueue = QueueActor<Livekit_SignalResponse>(onProcess: { [weak self] response in
        guard let self else { return }

        await _process(signalResponse: response)
    })

    private let _connectResponseCompleter = AsyncCompleter<ConnectResponse>(label: "Join response", defaultTimeout: .defaultJoinResponse)
    private let _addTrackCompleters = CompleterMapActor<Livekit_TrackInfo>(label: "Completers for add track", defaultTimeout: .defaultPublish)
    private let _pingIntervalTimer = AsyncTimer(interval: 1)
    private let _pingTimeoutTimer = AsyncTimer(interval: 1)

    struct State {
        var connectionState: ConnectionState = .disconnected
        var disconnectError: LiveKitError?
        var socket: WebSocket?
        var messageLoopTask: Task<Void, Never>?
        var lastJoinResponse: Livekit_JoinResponse?
        var rtt: Int64 = 0
    }

    let _state = StateSync(State())

    init() {
        log()
        _state.onDidMutate = { [weak self] newState, oldState in
            guard let self else { return }
            // ConnectionState
            if oldState.connectionState != newState.connectionState {
                log("\(oldState.connectionState) -> \(newState.connectionState)")
                _delegate.notifyDetached { await $0.signalClient(self, didUpdateConnectionState: newState.connectionState, oldState: oldState.connectionState, disconnectError: self.disconnectError) }
            }
        }
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

        _state.mutate { $0.connectionState = (reconnectMode != nil ? .reconnecting : .connecting) }

        do {
            let socket = try await WebSocket(url: url, connectOptions: connectOptions)

            let task = Task.detached {
                self.log("Did enter WebSocket message loop...")
                do {
                    for try await message in socket {
                        await self._onWebSocketMessage(message: message)
                    }
                } catch {
                    await self.cleanUp(withError: error)
                }
            }
            _state.mutate { $0.messageLoopTask = task }

            let connectResponse = try await _connectResponseCompleter.wait()
            // Check cancellation after received join response
            try Task.checkCancellation()

            // Successfully connected
            _state.mutate {
                $0.socket = socket
                $0.connectionState = .connected
            }

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

        // Cancel ping/pong timers immediately to prevent stale timers from affecting future connections
        _pingIntervalTimer.cancel()
        _pingTimeoutTimer.cancel()

        _state.mutate {
            $0.messageLoopTask?.cancel()
            $0.messageLoopTask = nil
            $0.socket?.close()
            $0.socket = nil
            $0.lastJoinResponse = nil
        }

        _connectResponseCompleter.reset()

        await _addTrackCompleters.reset()
        await _requestQueue.clear()
        await _responseQueue.clear()

        _state.mutate {
            $0.disconnectError = LiveKitError.from(error: disconnectError)
            $0.connectionState = .disconnected
        }
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
        let response: Livekit_SignalResponse? = switch message {
        case let .data(data): try? Livekit_SignalResponse(serializedBytes: data)
        case let .string(string): try? Livekit_SignalResponse(jsonString: string)
        default: nil
        }

        guard let response else {
            log("Failed to decode SignalResponse", .warning)
            return
        }

        Task.detached {
            let alwaysProcess = switch response.message {
            case .join, .reconnect, .leave: true
            default: false
            }
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
            _state.mutate { $0.lastJoinResponse = joinResponse }
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

        case let .pongResp(pongResp):
            await _onReceivedPongResp(pongResp)

        case .subscriptionResponse:
            log("Received subscriptionResponse message")

        case .requestResponse:
            log("Received requestResponse message")

        case let .trackSubscribed(trackSubscribed):
            _delegate.notifyDetached { await $0.signalClient(self, didSubscribeTrack: Track.Sid(from: trackSubscribed.trackSid)) }

        case .roomMoved:
            log("Received roomMoved message")
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

    func sendAddTrack(cid: String,
                      name: String,
                      type: Livekit_TrackType,
                      source: Livekit_TrackSource = .unknown,
                      encryption: Livekit_Encryption.TypeEnum = .none,
                      _ populator: AddTrackRequestPopulator) async throws -> Livekit_TrackInfo
    {
        var addTrackRequest = Livekit_AddTrackRequest.with {
            $0.cid = cid
            $0.name = name
            $0.type = type
            $0.source = source
            $0.encryption = encryption
        }

        try populator(&addTrackRequest)

        let request = Livekit_SignalRequest.with {
            $0.addTrack = addTrackRequest
        }

        // Get completer for this add track request...
        let completer = await _addTrackCompleters.completer(for: cid)

        // Send the request to server...
        try await _sendRequest(request)

        // Wait for the trackInfo...
        let trackInfo = try await completer.wait()

        return trackInfo
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
                       dataChannels: [Livekit_DataChannelInfo]? = nil,
                       dataChannelReceiveStates: [Livekit_DataChannelReceiveState]? = nil) async throws
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
                $0.datachannelReceiveStates = dataChannelReceiveStates ?? []
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
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000) // Convert to milliseconds
        let rtt = _state.read { $0.rtt }

        // Send both ping and pingReq for compatibility with older and newer servers
        let pingRequest = Livekit_SignalRequest.with {
            $0.ping = timestamp
        }

        // Include the current RTT value in pingReq to report back to server
        let pingReqRequest = Livekit_SignalRequest.with {
            $0.pingReq = Livekit_Ping.with {
                $0.timestamp = timestamp
                $0.rtt = rtt // Send current RTT back to server
            }
        }

        // Log timestamp and RTT for debugging
        log("Sending ping with timestamp: \(timestamp)ms, reporting RTT: \(rtt)ms", .trace)

        // Send both requests
        try await _sendRequest(pingRequest)
        try await _sendRequest(pingReqRequest)
    }
}

// MARK: - Server ping/pong logic

private extension SignalClient {
    func _onPingIntervalTimer() async throws {
        guard let jr = _state.lastJoinResponse else { return }
        log("ping/pong sending ping...", .trace)
        try await _sendPing()

        _pingTimeoutTimer.setTimerInterval(TimeInterval(jr.pingTimeout))
        _pingTimeoutTimer.setTimerBlock { [weak self] in
            guard let self else { return }
            log("ping/pong timed out", .error)
            await cleanUp(withError: LiveKitError(.serverPingTimedOut))
        }

        _pingTimeoutTimer.restart()
    }

    func _onReceivedPong(_: Int64) async {
        log("ping/pong received pong from server", .trace)
        // Clear timeout timer
        _pingTimeoutTimer.cancel()
    }

    func _onReceivedPongResp(_ pongResp: Livekit_Pong) async {
        let currentTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
        let rtt = currentTimeMs - pongResp.lastPingTimestamp
        _state.mutate { $0.rtt = rtt }
        log("ping/pong received pongResp from server with RTT: \(rtt)ms", .trace)
        // Clear timeout timer
        _pingTimeoutTimer.cancel()
    }

    func _restartPingTimer() async {
        // Always cancel first...
        _pingIntervalTimer.cancel()
        _pingTimeoutTimer.cancel()

        // Check previously received joinResponse
        guard let jr = _state.lastJoinResponse,
              // Check if server supports ping/pong
              jr.pingTimeout > 0,
              jr.pingInterval > 0 else { return }

        log("ping/pong starting with interval: \(jr.pingInterval), timeout: \(jr.pingTimeout)")

        // Update interval...
        _pingIntervalTimer.setTimerInterval(TimeInterval(jr.pingInterval))
        _pingIntervalTimer.setTimerBlock { [weak self] in
            guard let self else { return }
            try await _onPingIntervalTimer()
        }
        _pingIntervalTimer.restart()
    }
}

extension Livekit_SignalRequest {
    func canBeQueued() -> Bool {
        switch message {
        case .syncState, .trickle, .offer, .answer, .simulate, .leave: false
        default: true
        }
    }
}

private extension SignalClient {
    func requireWebSocket() async throws -> WebSocket {
        guard let result = _state.socket else {
            log("WebSocket is nil", .error)
            throw LiveKitError(.invalidState, message: "WebSocket is nil")
        }

        return result
    }
}
