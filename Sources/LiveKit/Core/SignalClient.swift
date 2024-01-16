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

@_implementationOnly import WebRTC

class SignalClient: MulticastDelegate<SignalClientDelegate> {
    // MARK: - Types

    typealias AddTrackRequestPopulator<R> = (inout Livekit_AddTrackRequest) throws -> R
    typealias AddTrackResult<R> = (result: R, trackInfo: Livekit_TrackInfo)

    // MARK: - Internal

    public struct State: Equatable {
        var connectionState: ConnectionState = .disconnected
        var disconnectError: LiveKitError?
    }

    public enum ConnectResponse {
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

    // MARK: - Private

    private let _state = StateSync(State())

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

            let webSocket = try self.requireWebSocket()
            try await webSocket.send(data: data)

        } catch {
            self.log("Failed to send queued request \(request) with error: \(error)", .error)
        }
    })

    private lazy var _responseQueue = QueueActor<Livekit_SignalResponse>(onProcess: { [weak self] response in
        guard let self else { return }

        await self._process(signalResponse: response)
    })

    private var _webSocket: WebSocket?
    private var _messageLoopTask: Task<Void, Never>?
    private var latestJoinResponse: Livekit_JoinResponse?

    private let _connectResponseCompleter = AsyncCompleter<ConnectResponse>(label: "Join response", defaultTimeOut: .defaultJoinResponse)
    private let _addTrackCompleters = CompleterMapActor<Livekit_TrackInfo>(label: "Completers for add track", defaultTimeOut: .defaultPublish)

    private var _pingIntervalTimer: DispatchQueueTimer?
    private var _pingTimeoutTimer: DispatchQueueTimer?

    init() {
        super.init()

        log()

        // Trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in

            guard let self else { return }

            // connectionState Updated...
            if newState.connectionState != oldState.connectionState {
                self.log("\(oldState.connectionState) -> \(newState.connectionState)")
            }

            self.notify { $0.signalClient(self, didMutateState: newState, oldState: oldState) }
        }
    }

    deinit {
        log()
    }

    @discardableResult
    func connect(_ urlString: String,
                 _ token: String,
                 connectOptions: ConnectOptions? = nil,
                 reconnectMode: ReconnectMode? = nil,
                 adaptiveStream: Bool) async throws -> ConnectResponse
    {
        await cleanUp()

        // Start suspended...
        await _responseQueue.suspend()

        if let reconnectMode {
            log("[Connect] mode: \(String(describing: reconnectMode))")
        }

        guard let url = Utils.buildUrl(urlString,
                                       token,
                                       connectOptions: connectOptions,
                                       reconnectMode: reconnectMode,
                                       adaptiveStream: adaptiveStream)
        else {
            throw LiveKitError(.failedToParseUrl)
        }

        if reconnectMode != nil {
            log("[Connect] with url: \(url)")
        } else {
            log("Connecting with url: \(url)")
        }

        _state.mutate { $0.connectionState = (reconnectMode != nil ? .reconnecting : .connecting) }

        do {
            let socket = try await WebSocket(url: url)

            _messageLoopTask = Task.detached {
                self.log("Did enter WebSocket message loop...")
                do {
                    for try await message in socket {
                        self._onWebSocketMessage(message: message)
                    }
                } catch {
                    await self.cleanUp(withError: error)
                }
                self.log("Did exit WebSocket message loop...")
            }

            let connectResponse = try await _connectResponseCompleter.wait()
            // Check cancellation after received join response
            try Task.checkCancellation()

            // Successfully connected
            _webSocket = socket
            _state.mutate { $0.connectionState = .connected }

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
            guard let validateUrl = Utils.buildUrl(urlString,
                                                   token,
                                                   connectOptions: connectOptions,
                                                   adaptiveStream: adaptiveStream,
                                                   validate: true)
            else {
                throw LiveKitError(.failedToParseUrl, message: "Failed to parse validation url")
            }

            log("Validating with url: \(validateUrl)...")
            let validationResponse = try await HTTP.requestString(from: validateUrl)
            log("Validate response: \(validationResponse)")
            // re-throw with validation response
            throw LiveKitError(.network, message: "Validation response: \"\(validationResponse)\"")
        }
    }

    func cleanUp(withError disconnectError: Error? = nil) async {
        log("withError: \(String(describing: disconnectError))")

        _state.mutate {
            $0.connectionState = .disconnected
            $0.disconnectError = LiveKitError.from(error: disconnectError)
        }

        _pingIntervalTimer = nil
        _pingTimeoutTimer = nil

        _messageLoopTask?.cancel()
        _messageLoopTask = nil

        _webSocket?.close()
        _webSocket = nil

        _connectResponseCompleter.reset()
        latestJoinResponse = nil

        // Reset state
        _state.mutate { $0 = State() }

        await _addTrackCompleters.reset()
        await _requestQueue.clear()
        await _responseQueue.clear()
    }
}

// MARK: - Private

private extension SignalClient {
    // Send request or enqueue while reconnecting
    func _sendRequest(_ request: Livekit_SignalRequest) async throws {
        guard _state.connectionState != .disconnected else {
            log("connectionState is .disconnected", .error)
            throw LiveKitError(.invalidState, message: "connectionState is .disconnected")
        }

        let processImmediately = !(_state.connectionState == .reconnecting && request.canEnqueue())
        await _requestQueue.process(request, if: processImmediately)
    }

    func _onWebSocketMessage(message: URLSessionWebSocketTask.Message) {
        let response: Livekit_SignalResponse? = {
            switch message {
            case let .data(data): return try? Livekit_SignalResponse(contiguousBytes: data)
            case let .string(string): return try? Livekit_SignalResponse(jsonString: string)
            default: return nil
            }
        }()

        guard let response else {
            log("Failed to decode SignalResponse", .warning)
            return
        }

        Task {
            let isJoinOrReconnect: Bool = {
                switch response.message {
                case .join, .reconnect: return true
                default: return false
                }
            }()
            // Always process join or reconnect messages even if suspended...
            await _responseQueue.processIfResumed(response, or: isJoinOrReconnect)
        }
    }

    func _process(signalResponse: Livekit_SignalResponse) async {
        guard _state.connectionState != .disconnected else {
            log("connectionState is .disconnected", .error)
            return
        }

        guard let message = signalResponse.message else {
            log("Failed to decode SignalResponse", .warning)
            return
        }

        switch message {
        case let .join(joinResponse):
            latestJoinResponse = joinResponse
            restartPingTimer()
            notify { $0.signalClient(self, didReceiveConnectResponse: .join(joinResponse)) }
            _connectResponseCompleter.resume(returning: .join(joinResponse))

        case let .reconnect(response):
            restartPingTimer()
            notify { $0.signalClient(self, didReceiveConnectResponse: .reconnect(response)) }
            _connectResponseCompleter.resume(returning: .reconnect(response))

        case let .answer(sd):
            notify { $0.signalClient(self, didReceiveAnswer: sd.toRTCType()) }

        case let .offer(sd):
            notify { $0.signalClient(self, didReceiveOffer: sd.toRTCType()) }

        case let .trickle(trickle):
            guard let rtcCandidate = try? Engine.createIceCandidate(fromJsonString: trickle.candidateInit) else {
                return
            }

            notify { $0.signalClient(self, didReceiveIceCandidate: rtcCandidate, target: trickle.target) }

        case let .update(update):
            notify { $0.signalClient(self, didUpdateParticipants: update.participants) }

        case let .roomUpdate(update):
            notify { $0.signalClient(self, didUpdateRoom: update.room) }

        case let .trackPublished(trackPublished):
            // not required to be handled because we use completer pattern for this case
            notify { $0.signalClient(self, didPublishLocalTrack: trackPublished) }

            log("[publish] resolving completer for cid: \(trackPublished.cid)")
            // Complete
            await _addTrackCompleters.resume(returning: trackPublished.track, for: trackPublished.cid)

        case let .trackUnpublished(trackUnpublished):
            notify { $0.signalClient(self, didUnpublishLocalTrack: trackUnpublished) }

        case let .speakersChanged(speakers):
            notify { $0.signalClient(self, didUpdateSpeakers: speakers.speakers) }

        case let .connectionQuality(quality):
            notify { $0.signalClient(self, didUpdateConnectionQuality: quality.updates) }

        case let .mute(mute):
            notify { $0.signalClient(self, didUpdateRemoteMute: mute.sid, muted: mute.muted) }

        case let .leave(leave):
            notify { $0.signalClient(self, didReceiveLeave: leave.canReconnect, reason: leave.reason) }

        case let .streamStateUpdate(states):
            notify { $0.signalClient(self, didUpdateTrackStreamStates: states.streamStates) }

        case let .subscribedQualityUpdate(update):
            notify { $0.signalClient(self, didUpdateSubscribedCodecs: update.subscribedCodecs,
                                     qualities: update.subscribedQualities,
                                     forTrackSid: update.trackSid) }

        case let .subscriptionPermissionUpdate(permissionUpdate):
            notify { $0.signalClient(self, didUpdateSubscriptionPermission: permissionUpdate) }
        case let .refreshToken(token):
            notify { $0.signalClient(self, didUpdateToken: token) }
        case let .pong(r):
            onReceivedPong(r)
        case .pongResp:
            log("received pongResp message")
        case .subscriptionResponse:
            log("received subscriptionResponse message")
        }
    }
}

// MARK: - Internal

extension SignalClient {
    func resumeResponseQueue() async {
        await _responseQueue.resume()
    }
}

// MARK: - Send methods

extension SignalClient {
    func resumeRequestQueue() async throws {
        let queueCount = await _requestQueue.count
        log("[Connect] Sending queued requests (\(queueCount))...")

        await _requestQueue.resume()
    }

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

    func sendCandidate(candidate: LKRTCIceCandidate, target: Livekit_SignalTarget) async throws {
        let r = try Livekit_SignalRequest.with {
            $0.trickle = try Livekit_TrickleRequest.with {
                $0.target = target
                $0.candidateInit = try candidate.toLKType().toJsonString()
            }
        }

        try await _sendRequest(r)
    }

    func sendMuteTrack(trackSid: String, muted: Bool) async throws {
        let r = Livekit_SignalRequest.with {
            $0.mute = Livekit_MuteTrackRequest.with {
                $0.sid = trackSid
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

    func sendUpdateTrackSettings(sid: Sid, settings: TrackSettings) async throws {
        let r = Livekit_SignalRequest.with {
            $0.trackSetting = Livekit_UpdateTrackSettings.with {
                $0.trackSids = [sid]
                $0.disabled = !settings.isEnabled
                $0.width = UInt32(settings.dimensions.width)
                $0.height = UInt32(settings.dimensions.height)
                $0.quality = settings.videoQuality.toPBType()
                $0.fps = UInt32(settings.preferredFPS)
            }
        }

        try await _sendRequest(r)
    }

    func sendUpdateVideoLayers(trackSid: Sid,
                               layers: [Livekit_VideoLayer]) async throws
    {
        let r = Livekit_SignalRequest.with {
            $0.updateLayers = Livekit_UpdateVideoLayers.with {
                $0.trackSid = trackSid
                $0.layers = layers
            }
        }

        try await _sendRequest(r)
    }

    func sendUpdateSubscription(participantSid: Sid,
                                trackSid: String,
                                isSubscribed: Bool) async throws
    {
        let p = Livekit_ParticipantTracks.with {
            $0.participantSid = participantSid
            $0.trackSids = [trackSid]
        }

        let r = Livekit_SignalRequest.with {
            $0.subscription = Livekit_UpdateSubscription.with {
                $0.trackSids = [trackSid] // Deprecated
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

    func sendUpdateLocalMetadata(_ metadata: String, name: String) async throws {
        let r = Livekit_SignalRequest.with {
            $0.updateMetadata = Livekit_UpdateParticipantMetadata.with {
                $0.metadata = metadata
                $0.name = name
            }
        }

        try await _sendRequest(r)
    }

    func sendSyncState(answer: Livekit_SessionDescription,
                       offer: Livekit_SessionDescription?,
                       subscription: Livekit_UpdateSubscription,
                       publishTracks: [Livekit_TrackPublishedResponse]? = nil,
                       dataChannels: [Livekit_DataChannelInfo]? = nil) async throws
    {
        let r = Livekit_SignalRequest.with {
            $0.syncState = Livekit_SyncState.with {
                $0.answer = answer
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
                }
            }
        }

        defer {
            if shouldDisconnect {
                Task {
                    await cleanUp()
                }
            }
        }

        try await _sendRequest(r)
    }

    private func sendPing() async throws {
        let r = Livekit_SignalRequest.with {
            $0.ping = Int64(Date().timeIntervalSince1970)
        }

        try await _sendRequest(r)
    }
}

// MARK: - Server ping/pong logic

private extension SignalClient {
    func onPingIntervalTimer() async throws {
        guard let jr = latestJoinResponse else { return }

        try await sendPing()

        if _pingTimeoutTimer == nil {
            // start timeout timer

            _pingTimeoutTimer = {
                let timer = DispatchQueueTimer(timeInterval: TimeInterval(jr.pingTimeout), queue: self._queue)
                timer.handler = { [weak self] in
                    guard let self else { return }
                    self.log("ping/pong timed out", .error)
                    Task {
                        await self.cleanUp(withError: LiveKitError(.serverPingTimedOut))
                    }
                }
                timer.resume()
                return timer
            }()
        }
    }

    func onReceivedPong(_: Int64) {
        log("ping/pong received pong from server", .trace)
        // clear timeout timer
        _pingTimeoutTimer = nil
    }

    func restartPingTimer() {
        // always suspend first
        _pingIntervalTimer = nil
        _pingTimeoutTimer = nil
        // check received joinResponse already
        guard let jr = latestJoinResponse,
              // check server supports ping/pong
              jr.pingTimeout > 0,
              jr.pingInterval > 0 else { return }

        log("ping/pong starting with interval: \(jr.pingInterval), timeout: \(jr.pingTimeout)")

        _pingIntervalTimer = {
            let timer = DispatchQueueTimer(timeInterval: TimeInterval(jr.pingInterval), queue: _queue)
            timer.handler = { [weak self] in
                Task { [weak self] in
                    try await self?.onPingIntervalTimer()
                }
            }
            timer.resume()
            return timer
        }()
    }
}

extension Livekit_SignalRequest {
    func canEnqueue() -> Bool {
        switch message {
        case .syncState: return false
        case .trickle: return false
        case .offer: return false
        case .answer: return false
        case .simulate: return false
        case .leave: return false
        default: return true
        }
    }
}

private extension SignalClient {
    func requireWebSocket() throws -> WebSocket {
        // This shouldn't happen
        guard let result = _webSocket else {
            log("WebSocket is nil", .error)
            throw LiveKitError(.invalidState, message: "WebSocket is nil")
        }

        return result
    }
}
