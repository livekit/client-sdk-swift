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

import Foundation

internal import LiveKitWebRTC

actor SignalClient: Loggable {
    // MARK: - Types

    typealias AddTrackRequestPopulator = @Sendable (inout Livekit_AddTrackRequest.Builder) throws -> Void

    enum ConnectResponse {
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

    /// A response handed over as received, for consumers that decode the wire format themselves.
    ///
    /// Delivered after the decoded form of the same message, so the room has already applied it.
    enum EncodedResponse {
        case join(Data)
        case participantUpdate(Data)
    }

    // MARK: - Public

    var connectionState: ConnectionState { _state.connectionState }

    var disconnectError: LiveKitError? { _state.disconnectError }

    var useV0SignalPath: Bool { _state.useV0SignalPath }

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

    // Queued with the bytes it arrived as, not just the decoded form: consumers that parse the
    // wire format themselves (the data track managers) need the original encoding, and
    // re-encoding our decoded copy would drop every field this client's protocol pin doesn't
    // know — nanopb discards unknown fields on decode.
    private lazy var _responseQueue = QueueActor<(response: Livekit_SignalResponse, encoded: Data)>(onProcess: { [weak self] element in
        guard let self else { return }

        await _process(element.response, encoded: element.encoded)
    })

    private let _connectResponseCompleter = AsyncCompleter<ConnectResponse>(label: "Join response", defaultTimeout: .defaultJoinResponse)
    private let _addTrackCompleters = CompleterMapActor<Livekit_TrackInfo>(label: "Completers for add track", defaultTimeout: .defaultPublish)
    private let _pingIntervalTimer = AsyncTimer(interval: 1)
    private let _pingTimeoutTimer = AsyncTimer(interval: 1)

    struct State {
        var connectionState: ConnectionState = .disconnected
        var disconnectError: LiveKitError?
        var socket: WebSocket?
        var messageLoopTask: AnyTaskCancellable?
        var lastJoinResponse: Livekit_JoinResponse?
        var rtt: Int64 = 0
        // Tracks whether the v0 signal path (/rtc) is in use, set during connect.
        // Reused by reconnect to avoid re-attempting the unsupported v1 path.
        var useV0SignalPath: Bool = false
    }

    let _state = StateSync(State())

    // The data-track managers parse signal responses themselves, so the ones they consume are
    // forwarded as raw protobuf bytes. They drain through a single consumer task per connection,
    // so the managers see them in wire order — a detached task per message could reorder e.g. a
    // publish/unpublish response pair. The path deliberately bypasses `_responseQueue`: the
    // managers own their reconnect semantics (republish, subscription re-requests, sync state)
    // and consume wire order directly. Connection-scoped — started in `connect`, stopped in
    // `cleanUp` — so messages still buffered from a dead connection are dropped, not applied to
    // the next.
    private var _dataTrackResponses: AsyncStream<Data>.Continuation?
    private var _dataTrackResponsesConsumer: AnyTaskCancellable?

    // Requests the SFU answers by echoing an id, keyed by it. The counter is shared so ids stay
    // unique per connection; data blobs are the only user today. (Data track publishes also
    // report failures through `RequestResponse`, but correlate on the echoed request instead.)
    private var _nextRequestId: UInt32 = 0
    private var _dataBlobCompleters: [UInt32: AsyncCompleter<Data>] = [:]

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

    @discardableResult
    // swiftlint:disable:next function_body_length
    func connect(_ url: URL,
                 _ token: String,
                 connectOptions: ConnectOptions? = nil,
                 reconnectMode: ReconnectMode? = nil,
                 participantSid: Participant.Sid? = nil,
                 adaptiveStream: Bool,
                 singlePeerConnection: Bool,
                 connectSpan: Span? = nil) async throws -> ConnectResponse
    {
        await cleanUp()

        if let reconnectMode {
            log("[Connect] mode: \(String(describing: reconnectMode))")
        }

        let url: URL = if singlePeerConnection {
            try Utils.buildJoinRequestUrl(url,
                                          connectOptions: connectOptions,
                                          reconnectMode: reconnectMode,
                                          participantSid: participantSid,
                                          adaptiveStream: adaptiveStream)
        } else {
            try Utils.buildUrl(url,
                               connectOptions: connectOptions,
                               reconnectMode: reconnectMode,
                               participantSid: participantSid,
                               adaptiveStream: adaptiveStream)
        }

        _state.mutate { $0.useV0SignalPath = !singlePeerConnection }

        let isReconnect = reconnectMode != nil

        if isReconnect {
            log("Reconnecting with url: \(url)")
        } else {
            log("Connecting with url: \(url)")
        }

        _state.mutate { $0.connectionState = (isReconnect ? .reconnecting : .connecting) }

        do {
            let socket = try await WebSocket(url: url,
                                             token: token,
                                             connectOptions: connectOptions)
            connectSpan?.record("ws_open")

            startDataTrackResponses()

            let messageLoopTask = socket.subscribe(self) { observer, message in
                await observer.onWebSocketMessage(message)
            } onFailure: { observer, error in
                await observer.cleanUp(withError: error)
            }
            _state.mutate { $0.messageLoopTask = messageLoopTask }

            let connectResponse = try await _connectResponseCompleter.wait()
            // Check cancellation after received join response
            try Task.checkCancellation()

            // Successfully connected
            _state.mutate {
                $0.socket = socket
                $0.connectionState = .connected
            }

            return connectResponse
        } catch let connectionError {
            // Skip validation if user cancelled
            if connectionError is CancellationError {
                await cleanUp(withError: connectionError)
                throw connectionError
            }

            // Skip validation if reconnect mode
            if reconnectMode != nil {
                await cleanUp(withError: connectionError)
                throw LiveKitError(.network, internalError: connectionError)
            }

            await cleanUp(withError: connectionError)

            // Attempt to validate with server, deriving validate URL from the actual WS URL
            let validateUrl = try Utils.toValidateUrl(url)
            log("Validating with url: \(validateUrl)...")
            do {
                try await HTTP.requestValidation(from: validateUrl, token: token)
                // Re-throw original error since validation passed
                throw LiveKitError(.network, internalError: connectionError)
            } catch let error as LiveKitError where error.type == .serviceNotFound {
                throw error
            } catch let validationError as LiveKitError where validationError.type == .validation {
                // Re-throw validation error
                throw validationError
            } catch {
                let validationMessage = if let liveKitError = error as? LiveKitError {
                    liveKitError.message ?? liveKitError.localizedDescription
                } else {
                    error.localizedDescription
                }

                // Preserve validation request failure details while keeping the original connection error.
                throw LiveKitError(.network,
                                   message: "Validation request failed: \(validationMessage)",
                                   internalError: connectionError)
            }
        }
    }

    // Tears down connection state: closes socket, cancels timers, resets completers.
    //
    // Non-throwing: timer.cancel(), _state.mutate, completer.reset(),
    // queue.clear() are all `async` but never `try`. CancellationError
    // cannot interrupt the sequence.
    //
    // Idempotent: closing a nil socket, cancelling a stopped timer, or
    // resetting an empty completer are all safe no-ops.
    //
    // Must never be guarded by Task.isCancelled — see Room.cleanUp()
    // for the full cancellation contract.
    //
    // Only called from:
    //   Room.cleanUp()           ──► forwards disconnectError
    //   subscribe() onFailure    ──► WebSocket error (guarded: suppressed when
    //                                Task.isCancelled, preventing stale loops
    //                                from tearing down a new connection)
    func cleanUp(withError disconnectError: Error? = nil) async {
        log("withError: \(String(describing: disconnectError))")

        // Cancel ping/pong timers immediately to prevent stale timers from affecting future connections
        _pingIntervalTimer.cancel()
        _pingTimeoutTimer.cancel()

        _state.mutate {
            $0.messageLoopTask = nil
            $0.socket?.close()
            $0.socket = nil
            $0.lastJoinResponse = nil
        }

        _connectResponseCompleter.reset(throwing: disconnectError)

        await _addTrackCompleters.reset(throwing: disconnectError)
        for completer in _dataBlobCompleters.values {
            completer.reset(throwing: disconnectError)
        }
        _dataBlobCompleters.removeAll()
        await _requestQueue.clear()
        await _responseQueue.clear()
        stopDataTrackResponses()

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

    /// Starts delivering data-track responses for a new connection; see the property note.
    func startDataTrackResponses() {
        let (responses, continuation) = AsyncStream.makeStream(of: Data.self)
        _dataTrackResponses = continuation
        _dataTrackResponsesConsumer = Task { [weak self] in
            for await data in responses {
                guard let self else { break }
                try? await _delegate.notifyAsync { await $0.signalClient(self, didReceiveDataTrackResponse: data) }
            }
        }.cancellable()
    }

    /// Stops delivery and drops anything still buffered from the connection being torn down
    /// (releasing the consumer cancels it; finishing alone would let it drain the backlog).
    func stopDataTrackResponses() {
        _dataTrackResponses?.finish()
        _dataTrackResponses = nil
        _dataTrackResponsesConsumer = nil
    }

    func onWebSocketMessage(_ message: URLSessionWebSocketTask.Message) async {
        // The server mirrors the client's encoding and this SDK has sent
        // binary protobuf since 2021, so text (JSON) frames cannot occur
        // against livekit-server; they are unsupported here (as on Android).
        if case .string = message {
            log("Received JSON signal message, unsupported in this version.", .warning)
            return
        }

        guard case let .data(rawData) = message,
              let response = try? Livekit_SignalResponse(serializedBytes: rawData)
        else {
            log("Failed to decode SignalResponse", .warning)
            return
        }

        // Forward only what the data-track managers consume; every other message would cross the
        // FFI boundary just to be rejected as an unsupported type. `requestResponse` carries
        // publish request errors, so it belongs here even though it isn't data-track-specific.
        switch response.message {
        case .requestResponse, .publishDataTrackResponse, .dataTrackSubscriberHandles:
            _dataTrackResponses?.yield(rawData)
        default: break
        }

        Task.detached {
            let alwaysProcess = switch response.message {
            case .join, .reconnect, .leave: true
            default: false
            }
            // Always process join or reconnect messages even if suspended...
            await self._responseQueue.processIfResumed((response: response, encoded: rawData), or: alwaysProcess)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func _process(_ signalResponse: Livekit_SignalResponse, encoded: Data) async {
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
            // owned: the oneof getter hands out a view into the decoded
            // `SignalResponse`, and this is kept for the whole session
            _state.mutate { $0.lastJoinResponse = joinResponse.owned() }
            // Awaited, and the encoded form second: consumers that parse the wire format
            // themselves must see it only after the room has applied the decoded one, and
            // `notifyDetached` gives no ordering between two calls — each races to the serial
            // runner in its own detached task.
            try? await _delegate.notifyAsync { await $0.signalClient(self, didReceiveConnectResponse: .join(joinResponse)) }
            try? await _delegate.notifyAsync { await $0.signalClient(self, didReceiveEncodedResponse: .join(encoded)) }
            _connectResponseCompleter.resume(returning: .join(joinResponse))
            await _restartPingTimer()

        case let .reconnect(response):
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveConnectResponse: .reconnect(response)) }
            _connectResponseCompleter.resume(returning: .reconnect(response))
            await _restartPingTimer()

        case let .answer(sd):
            let (rtcDescription, offerId) = sd.toRTCType()
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveAnswer: rtcDescription, offerId: offerId) }

        case let .offer(sd):
            let (rtcDescription, offerId) = sd.toRTCType()
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveOffer: rtcDescription, offerId: offerId) }

        case let .trickle(trickle):
            guard let rtcCandidate = try? RTC.createIceCandidate(fromJsonString: trickle.candidateInit) else {
                return
            }

            _delegate.notifyDetached { await $0.signalClient(self, didReceiveIceCandidate: rtcCandidate.toLKType(), target: trickle.target) }

        case let .update(update):
            try? await _delegate.notifyAsync { await $0.signalClient(self, didUpdateParticipants: update.participants) }
            try? await _delegate.notifyAsync { await $0.signalClient(self, didReceiveEncodedResponse: .participantUpdate(encoded)) }

        case let .roomUpdate(update):
            _delegate.notifyDetached { await $0.signalClient(self, didUpdateRoom: update.room) }

        case let .roomMoved(response):
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveRoomMoved: response) }

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
            _delegate.notifyDetached {
                await $0.signalClient(self,
                                      didReceiveLeave: leave.action,
                                      reason: leave.reason,
                                      regions: leave.hasRegions ? leave.regions : nil)
            }

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

        case let .trackSubscribed(trackSubscribed):
            _delegate.notifyDetached { await $0.signalClient(self, didSubscribeTrack: Track.Sid(from: trackSubscribed.trackSid)) }

        case let .mediaSectionsRequirement(requirement):
            _delegate.notifyDetached { await $0.signalClient(self, didReceiveMediaSectionsRequirement: requirement) }

        case let .storeDataBlobResponse(response):
            _dataBlobCompleters[response.requestID]?.resume(returning: Data())

        case let .getDataBlobResponse(response):
            _dataBlobCompleters[response.requestID]?.resume(returning: response.blob.contents)

        case let .requestResponse(response):
            // The failure half of the id-correlated requests above; success arrives as the typed
            // response, so an acknowledgement (`ok`) or a progress report (`queued`) leaves the
            // request waiting. Anything else arriving here is for a request that reports its own
            // errors (data track publishes) or none.
            let isFailure = response.reason != .ok && response.reason != .queued
            if isFailure, let completer = _dataBlobCompleters[response.requestID] {
                let message = response.message.isEmpty ? "Request rejected (reason \(response.reason.rawValue))" : response.message
                completer.resume(throwing: LiveKitError(.invalidState, message: message))
            }

        case .publishDataTrackResponse, .dataTrackSubscriberHandles:
            // Handled by the data-track subsystem via didReceiveDataTrackResponse.
            break

        case .unpublishDataTrackResponse:
            // No data-track manager consumes this yet; unpublishes are tracked locally and, for
            // remote tracks, through participant updates.
            break

        default:
            log("Unhandled signal message: \(message)", .warning)
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
    func sendRequest(_ request: Livekit_SignalRequest) async throws {
        try await _sendRequest(request)
    }

    /// Stores a blob on the server under `key`, replacing nothing — a key can only be written once.
    func sendStoreDataBlob(key: Livekit_DataBlobKey, contents: Data) async throws {
        _ = try await _sendIdCorrelatedRequest { requestId in
            Livekit_SignalRequest.with {
                $0.storeDataBlobRequest = Livekit_StoreDataBlobRequest.with {
                    $0.requestID = requestId
                    $0.blob = Livekit_DataBlob.with {
                        $0.key = key
                        $0.contents = contents
                    }
                }
            }
        }
    }

    /// Reads back a blob `participantIdentity` stored under `key`.
    func sendGetDataBlob(key: Livekit_DataBlobKey, participantIdentity: String) async throws -> Data {
        try await _sendIdCorrelatedRequest { requestId in
            Livekit_SignalRequest.with {
                $0.getDataBlobRequest = Livekit_GetDataBlobRequest.with {
                    $0.requestID = requestId
                    $0.participantIdentity = participantIdentity
                    $0.key = key
                }
            }
        }
    }

    /// Sends a request the SFU answers by echoing its id, and waits for that answer.
    private func _sendIdCorrelatedRequest(_ build: (UInt32) -> Livekit_SignalRequest) async throws -> Data {
        _nextRequestId += 1
        let requestId = _nextRequestId
        let completer = AsyncCompleter<Data>(label: "Signal request \(requestId)", defaultTimeout: .defaultDataBlobRequest)
        _dataBlobCompleters[requestId] = completer
        defer { _dataBlobCompleters[requestId] = nil }
        try await _sendRequest(build(requestId))
        return try await completer.wait()
    }

    func send(offer: LKRTCSessionDescription, offerId: UInt32) async throws {
        let r = Livekit_SignalRequest.with {
            $0.offer = offer.toPBType(offerId: offerId)
        }

        try await _sendRequest(r)
    }

    func send(answer: LKRTCSessionDescription, offerId: UInt32) async throws {
        let r = Livekit_SignalRequest.with {
            $0.answer = answer.toPBType(offerId: offerId)
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
        let addTrackRequest = try Livekit_AddTrackRequest.with {
            $0.cid = cid
            $0.name = name
            $0.type = type
            $0.source = source
            $0.encryption = encryption
            try populator(&$0)
        }

        let request = Livekit_SignalRequest.with {
            $0.addTrack = addTrackRequest
        }

        // Get completer for this add track request...
        let completer = await _addTrackCompleters.completer(for: cid)

        // Send the request to server...
        try await _sendRequest(request)

        // Wait for the trackInfo...
        return try await completer.wait()
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
                       publishDataTracks: [Livekit_PublishDataTrackResponse]? = nil,
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
                $0.publishDataTracks = publishDataTracks ?? []
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

        // Send both requests
        try await _sendRequest(pingRequest)
        try await _sendRequest(pingReqRequest)
    }
}

// MARK: - Server ping/pong logic

private extension SignalClient {
    func _onPingIntervalTimer() async throws {
        guard let jr = _state.lastJoinResponse else { return }
        try await _sendPing()

        _pingTimeoutTimer.setTimerInterval(TimeInterval(jr.pingTimeout))
        _pingTimeoutTimer.setTimerBlock { [weak self] in
            guard let self else { return }
            log("ping/pong timed out", .error)
            await cleanUp(withError: LiveKitError(.serverPingTimedOut))
        }

        // Arm without resetting a running countdown, else every ping pushes the deadline out and it never fires.
        _pingTimeoutTimer.startIfStopped()
    }

    func _onReceivedPong(_: Int64) async {
        // Clear timeout timer
        _pingTimeoutTimer.cancel()
    }

    func _onReceivedPongResp(_ pongResp: Livekit_Pong) async {
        let currentTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
        let rtt = currentTimeMs - pongResp.lastPingTimestamp
        _state.mutate { $0.rtt = rtt }
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
