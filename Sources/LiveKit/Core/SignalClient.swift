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

@_implementationOnly import WebRTC

internal class SignalClient: MulticastDelegate<SignalClientDelegate> {

    // MARK: - Types

    typealias AddTrackRequestPopulator<R> = (inout Livekit_AddTrackRequest) throws -> R
    typealias AddTrackResult<R> = (result: R, trackInfo: Livekit_TrackInfo)

    private let queue = DispatchQueue(label: "LiveKitSDK.signalClient", qos: .default)

    // MARK: - Public

    public var connectionState: ConnectionState { _state.connectionState }

    // MARK: - Internal

    internal let joinResponseCompleter = AsyncCompleter<Livekit_JoinResponse>(label: "Join response", timeOut: .defaultJoinResponse)
    internal let _addTrackCompleters = CompleterMapActor<Livekit_TrackInfo>(label: "Completers for add track", timeOut: .defaultPublish)

    internal struct State: ReconnectableState, Equatable {
        var reconnectMode: ReconnectMode?
        var connectionState: ConnectionState = .disconnected()
    }

    internal var _state = StateSync(State())

    // MARK: - Private

    // Queue to store requests while reconnecting
    private let _requestQueue = AsyncQueueActor<Livekit_SignalRequest>()
    private let _responseQueue = AsyncQueueActor<Livekit_SignalResponse>()

    private var _webSocket: WebSocket?
    private var latestJoinResponse: Livekit_JoinResponse?

    private var pingIntervalTimer: DispatchQueueTimer?
    private var pingTimeoutTimer: DispatchQueueTimer?

    init() {
        super.init()

        log()

        // trigger events when state mutates
        self._state.onDidMutate = { [weak self] newState, oldState in

            guard let self = self else { return }

            // connectionState did update
            if newState.connectionState != oldState.connectionState {
                self.log("\(oldState.connectionState) -> \(newState.connectionState)")
            }

            self.notify { $0.signalClient(self, didMutate: newState, oldState: oldState) }
        }
    }

    deinit {
        log()
    }

    func connect(_ urlString: String,
                 _ token: String,
                 connectOptions: ConnectOptions? = nil,
                 reconnectMode: ReconnectMode? = nil,
                 adaptiveStream: Bool) async throws {

        await cleanUp()

        log("reconnectMode: \(String(describing: reconnectMode))")

        guard let url = Utils.buildUrl(urlString,
                                       token,
                                       connectOptions: connectOptions,
                                       reconnectMode: reconnectMode,
                                       adaptiveStream: adaptiveStream) else {

            throw InternalError.parse(message: "Failed to parse url")
        }

        log("Connecting with url: \(urlString)")

        _state.mutate {
            $0.reconnectMode = reconnectMode
            $0.connectionState = .connecting
        }

        let socket = WebSocket(url: url)

        do {
            try await socket.connect()
            _webSocket = socket
            _state.mutate { $0.connectionState = .connected }

            Task.detached {
                self.log("Did enter WebSocket message loop...")
                do {
                    for try await message in socket {
                        self.onWebSocketMessage(message: message)
                    }
                } catch {
                    await self.cleanUp(reason: .networkError(error))
                }
                self.log("Did exit WebSocket message loop...")
            }
        } catch let error {

            defer {
                Task {
                    await cleanUp(reason: .networkError(error))
                }
            }

            // Skip validation if reconnect mode
            if reconnectMode != nil { throw error }

            guard let validateUrl = Utils.buildUrl(urlString,
                                                   token,
                                                   connectOptions: connectOptions,
                                                   adaptiveStream: adaptiveStream,
                                                   validate: true) else {

                throw InternalError.parse(message: "Failed to parse validation url")
            }

            log("Validating with url: \(validateUrl)...")
            let validationResponse = try await HTTP.requestString(from: validateUrl)
            self.log("Validate response: \(validationResponse)")
            // re-throw with validation response
            throw SignalClientError.connect(message: "Validation response: \"\(validationResponse)\"")
        }
    }

    func cleanUp(reason: DisconnectReason? = nil) async {

        log("reason: \(String(describing: reason))")

        _state.mutate { $0.connectionState = .disconnected(reason: reason) }

        pingIntervalTimer = nil
        pingTimeoutTimer = nil

        if let socket = _webSocket {
            socket.reset()
            self._webSocket = nil
        }

        latestJoinResponse = nil

        _state.mutate {

            joinResponseCompleter.cancel()

            // reset state
            $0 = State()
        }

        await _addTrackCompleters.reset()
        await _requestQueue.clear()
        await _responseQueue.clear()
    }
}

// MARK: - Private

private extension SignalClient {

    // send request or enqueue while reconnecting
    func sendRequest(_ request: Livekit_SignalRequest, enqueueIfReconnecting: Bool = true) async throws {

        guard !(_state.connectionState.isReconnecting && request.canEnqueue() && enqueueIfReconnecting) else {
            log("Queuing request while reconnecting, request: \(request)")
            await _requestQueue.enqueue(request)
            return
        }

        guard case .connected = connectionState else {
            log("not connected", .error)
            throw SignalClientError.state(message: "Not connected")
        }

        guard let data = try? request.serializedData() else {
            log("could not serialize data", .error)
            throw InternalError.convert(message: "Could not serialize data")
        }

        let webSocket = try await requireWebSocket()

        try await webSocket.send(data: data)
    }

    func onWebSocketMessage(message: URLSessionWebSocketTask.Message) {

        var response: Livekit_SignalResponse?

        if case .data(let data) = message {
            response = try? Livekit_SignalResponse(contiguousBytes: data)
        } else if case .string(let string) = message {
            response = try? Livekit_SignalResponse(jsonString: string)
        }

        guard let response = response else {
            log("Failed to decode SignalResponse", .warning)
            return
        }

        Task {
            await _responseQueue.enqueue(response) { await processSignalResponse($0) }
        }
    }

    func processSignalResponse(_ response: Livekit_SignalResponse) async {

        guard case .connected = connectionState else {
            log("Not connected", .warning)
            return
        }

        guard let message = response.message else {
            log("Failed to decode SignalResponse", .warning)
            return
        }

        switch message {
        case .join(let joinResponse):
            await _responseQueue.suspend()
            latestJoinResponse = joinResponse
            restartPingTimer()
            notify { $0.signalClient(self, didReceive: joinResponse) }
            joinResponseCompleter.resume(returning: joinResponse)

        case .answer(let sd):
            notify { $0.signalClient(self, didReceiveAnswer: sd.toRTCType()) }

        case .offer(let sd):
            notify { $0.signalClient(self, didReceiveOffer: sd.toRTCType()) }

        case .trickle(let trickle):
            guard let rtcCandidate = try? Engine.createIceCandidate(fromJsonString: trickle.candidateInit) else {
                return
            }

            notify { $0.signalClient(self, didReceive: rtcCandidate, target: trickle.target) }

        case .update(let update):
            notify { $0.signalClient(self, didUpdate: update.participants) }

        case .roomUpdate(let update):
            notify { $0.signalClient(self, didUpdate: update.room) }

        case .trackPublished(let trackPublished):
            // not required to be handled because we use completer pattern for this case
            notify { $0.signalClient(self, didPublish: trackPublished) }

            log("[publish] resolving completer for cid: \(trackPublished.cid)")
            // Complete
            await _addTrackCompleters.resume(returning: trackPublished.track, for: trackPublished.cid)

        case .trackUnpublished(let trackUnpublished):
            notify { $0.signalClient(self, didUnpublish: trackUnpublished) }

        case .speakersChanged(let speakers):
            notify { $0.signalClient(self, didUpdate: speakers.speakers) }

        case .connectionQuality(let quality):
            notify { $0.signalClient(self, didUpdate: quality.updates) }

        case .mute(let mute):
            notify { $0.signalClient(self, didUpdateRemoteMute: mute.sid, muted: mute.muted) }

        case .leave(let leave):
            notify { $0.signalClient(self, didReceiveLeave: leave.canReconnect, reason: leave.reason) }

        case .streamStateUpdate(let states):
            notify { $0.signalClient(self, didUpdate: states.streamStates) }

        case .subscribedQualityUpdate(let update):
            // ignore 0.15.1
            if latestJoinResponse?.serverVersion == "0.15.1" {
                return
            }
            notify { $0.signalClient(self, didUpdate: update.trackSid, subscribedQualities: update.subscribedQualities)}
        case .subscriptionPermissionUpdate(let permissionUpdate):
            notify { $0.signalClient(self, didUpdate: permissionUpdate) }
        case .refreshToken(let token):
            notify { $0.signalClient(self, didUpdate: token) }
        case .pong(let r):
            onReceivedPong(r)
        case .reconnect:
            log("received reconnect message")
        case .pongResp:
            log("received pongResp message")
        case .subscriptionResponse:
            log("received subscriptionResponse message")
        }
    }
}

// MARK: - Internal

internal extension SignalClient {

    func resumeResponseQueue() async throws {

        await _responseQueue.resume { response in
            await processSignalResponse(response)
        }
    }
}

// MARK: - Send methods

internal extension SignalClient {

    func sendQueuedRequests() async throws {

        await _requestQueue.resume { element in
            do {
                try await sendRequest(element, enqueueIfReconnecting: false)
            } catch let error {
                log("Failed to send queued request \(element) with error: \(error)", .error)
            }
        }
    }

    func send(offer: LKRTCSessionDescription) async throws {

        let r = Livekit_SignalRequest.with {
            $0.offer = offer.toPBType()
        }

        try await sendRequest(r)
    }

    func send(answer: LKRTCSessionDescription) async throws {

        let r = Livekit_SignalRequest.with {
            $0.answer = answer.toPBType()
        }

        try await sendRequest(r)
    }

    func sendCandidate(candidate: LKRTCIceCandidate, target: Livekit_SignalTarget) async throws {

        let r = try Livekit_SignalRequest.with {
            $0.trickle = try Livekit_TrickleRequest.with {
                $0.target = target
                $0.candidateInit = try candidate.toLKType().toJsonString()
            }
        }

        try await sendRequest(r)
    }

    func sendMuteTrack(trackSid: String, muted: Bool) async throws {

        let r = Livekit_SignalRequest.with {
            $0.mute = Livekit_MuteTrackRequest.with {
                $0.sid = trackSid
                $0.muted = muted
            }
        }

        try await sendRequest(r)
    }

    func sendAddTrack<R>(cid: String,
                         name: String,
                         type: Livekit_TrackType,
                         source: Livekit_TrackSource = .unknown,
                         encryption: Livekit_Encryption.TypeEnum = .none,
                         _ populator: AddTrackRequestPopulator<R>) async throws -> AddTrackResult<R> {

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
        try await sendRequest(request)

        // Wait for the trackInfo...
        let trackInfo = try await completer.wait()

        return AddTrackResult(result: populateResult, trackInfo: trackInfo)
    }

    func sendUpdateTrackSettings(sid: Sid, settings: TrackSettings) async throws {

        let r = Livekit_SignalRequest.with {
            $0.trackSetting = Livekit_UpdateTrackSettings.with {
                $0.trackSids = [sid]
                $0.disabled = !settings.enabled
                $0.width = UInt32(settings.dimensions.width)
                $0.height = UInt32(settings.dimensions.height)
                $0.quality = settings.videoQuality.toPBType()
                $0.fps = UInt32(settings.preferredFPS)
            }
        }

        try await sendRequest(r)
    }

    func sendUpdateVideoLayers(trackSid: Sid,
                               layers: [Livekit_VideoLayer]) async throws {

        let r = Livekit_SignalRequest.with {
            $0.updateLayers = Livekit_UpdateVideoLayers.with {
                $0.trackSid = trackSid
                $0.layers = layers
            }
        }

        try await sendRequest(r)
    }

    func sendUpdateSubscription(participantSid: Sid,
                                trackSid: String,
                                subscribed: Bool) async throws {

        let p = Livekit_ParticipantTracks.with {
            $0.participantSid = participantSid
            $0.trackSids = [trackSid]
        }

        let r = Livekit_SignalRequest.with {
            $0.subscription = Livekit_UpdateSubscription.with {
                $0.trackSids = [trackSid] // Deprecated
                $0.participantTracks = [p]
                $0.subscribe = subscribed
            }
        }

        try await sendRequest(r)
    }

    func sendUpdateSubscriptionPermission(allParticipants: Bool,
                                          trackPermissions: [ParticipantTrackPermission]) async throws {

        let r = Livekit_SignalRequest.with {
            $0.subscriptionPermission = Livekit_SubscriptionPermission.with {
                $0.allParticipants = allParticipants
                $0.trackPermissions = trackPermissions.map({ $0.toPBType() })
            }
        }

        try await sendRequest(r)
    }

    func sendUpdateLocalMetadata(_ metadata: String, name: String) async throws {

        let r = Livekit_SignalRequest.with {
            $0.updateMetadata = Livekit_UpdateParticipantMetadata.with {
                $0.metadata = metadata
                $0.name = name
            }
        }

        try await sendRequest(r)
    }

    func sendSyncState(answer: Livekit_SessionDescription,
                       offer: Livekit_SessionDescription?,
                       subscription: Livekit_UpdateSubscription,
                       publishTracks: [Livekit_TrackPublishedResponse]? = nil,
                       dataChannels: [Livekit_DataChannelInfo]? = nil) async throws {

        let r = Livekit_SignalRequest.with {
            $0.syncState = Livekit_SyncState.with {
                $0.answer = answer
                if let offer = offer {
                    $0.offer = offer
                }
                $0.subscription = subscription
                $0.publishTracks = publishTracks ?? []
                $0.dataChannels = dataChannels ?? []
            }
        }

        try await sendRequest(r)
    }

    func sendLeave() async throws {

        let r = Livekit_SignalRequest.with {
            $0.leave = Livekit_LeaveRequest.with {
                $0.canReconnect = false
                $0.reason = .clientInitiated
            }
        }

        try await sendRequest(r)
    }

    func sendSimulate(scenario: SimulateScenario) async throws {

        var shouldDisconnect = false

        let r = Livekit_SignalRequest.with {
            $0.simulate = Livekit_SimulateScenario.with {
                switch scenario {
                case .nodeFailure: $0.nodeFailure = true
                case .migration: $0.migration = true
                case .serverLeave: $0.serverLeave = true
                case .speakerUpdate(let secs): $0.speakerUpdate = Int32(secs)
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
                    await cleanUp(reason: .networkError(NetworkError.disconnected(message: "Simulate scenario")))
                }
            }
        }

        try await sendRequest(r)
    }

    private func sendPing() async throws {

        let r = Livekit_SignalRequest.with {
            $0.ping = Int64(Date().timeIntervalSince1970)
        }

        try await sendRequest(r)
    }
}

// MARK: - Server ping/pong logic

private extension SignalClient {

    func onPingIntervalTimer() async throws {

        guard let jr = latestJoinResponse else { return }

        try await sendPing()

        if pingTimeoutTimer == nil {
            // start timeout timer

            pingTimeoutTimer = {
                let timer = DispatchQueueTimer(timeInterval: TimeInterval(jr.pingTimeout), queue: self.queue)
                timer.handler = { [weak self] in
                    guard let self = self else { return }
                    self.log("ping/pong timed out", .error)
                    Task {
                        await self.cleanUp(reason: .networkError(SignalClientError.serverPingTimedOut()))
                    }
                }
                timer.resume()
                return timer
            }()
        }
    }

    func onReceivedPong(_ r: Int64) {

        log("ping/pong received pong from server", .trace)
        // clear timeout timer
        pingTimeoutTimer = nil
    }

    func restartPingTimer() {
        // always suspend first
        pingIntervalTimer = nil
        pingTimeoutTimer = nil
        // check received joinResponse already
        guard let jr = latestJoinResponse,
              // check server supports ping/pong
              jr.pingTimeout > 0,
              jr.pingInterval > 0 else { return }

        log("ping/pong starting with interval: \(jr.pingInterval), timeout: \(jr.pingTimeout)")

        pingIntervalTimer = {
            let timer = DispatchQueueTimer(timeInterval: TimeInterval(jr.pingInterval), queue: queue)
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

internal extension Livekit_SignalRequest {

    func canEnqueue() -> Bool {
        switch self.message {
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

    func requireWebSocket() async throws -> WebSocket {
        // This shouldn't happen
        guard let result = _webSocket else {
            throw SignalClientError.state(message: "WebSocket is nil")
        }

        return result
    }
}
