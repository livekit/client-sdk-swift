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

internal import LiveKitUniFFI
import AVFoundation
import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// Room-scoped bridge to the Rust telemetry core (`livekit-telemetry`).
///
/// The SDK pushes what only it can observe — warn/error log records, per-track RTC statistics,
/// device state, session identity — and the core owns everything downstream: batching, RTC
/// windowing, the flood guard, the write-ahead cache, retry/backoff and the OTLP wire format.
/// Lives on ``ConnectionDependencies``: created when `connect()` starts (so pre-connect failures
/// are captured), carried across reconnects, shut down on disconnect.
final class RoomTelemetry: NSObject, @unchecked Sendable, Loggable {
    private let core: LiveKitUniFFI.Telemetry
    private weak var room: Room?
    private var notificationTokens: [NSObjectProtocol] = []
    /// Instruments run here, never on a media or UI thread.
    private let queue = DispatchQueue(label: "LiveKitSDK.telemetry", qos: .utility)
    private var memorySource: DispatchSourceMemoryPressure?
    private let pathMonitor = NWPathMonitor()

    private struct State {
        var appState: LiveKitUniFFI.AppState = .foreground
        var memory: MemoryPressure = .normal
        var network: NetworkType = .unknown
        var networkExpensive = false
        var networkConstrained = false
        /// Percent; `nil` where unknown (macOS, tvOS).
        var batteryLevel: UInt32?
        var batteryCharging = false
        /// Open `lk.subscribe` spans by track, from subscription intent to first media.
        var subscribeSpans: [Track.Sid: Span] = [:]
        var subscribeTimeouts: [Track.Sid: Task<Void, Never>] = [:]
    }

    /// A subscription that shows no media within this window ends with `error.type = timedOut`.
    static let subscribeTimeout: TimeInterval = 30

    private let _state = StateSync(State())

    /// `nil` only if the core refuses to start (no transport) — never the case here, but telemetry is
    /// fail-open: the room connects without it rather than not at all.
    init?(room: Room, options: TelemetryOptions) {
        let config = TelemetryConfig(
            endpoint: options.endpoint.absoluteString,
            headers: options.headers,
            resource: Self.resource(),
            storageDir: options.storageDirectory?.path,
            flushIntervalMs: UInt64(max(0, options.flushInterval) * 1000),
            statsWindowMs: UInt64(max(0, options.statsWindow) * 1000),
        )
        guard let core = try? LiveKitUniFFI.Telemetry(config: config, transport: URLSessionTelemetryTransport()) else {
            return nil
        }
        self.core = core
        self.room = room
        super.init()

        room.add(delegate: self)
        LogRelay.shared.sinks.add(delegate: self)

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                     object: nil, queue: nil) { [weak self] _ in self?.pushDeviceState() })
        if #available(macOS 12.0, iOS 9.0, tvOS 9.0, *) {
            notificationTokens.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                                         object: nil, queue: nil) { [weak self] _ in self?.pushDeviceState() })
        }
        Task { @MainActor in AppStateListener.shared.delegates.add(delegate: self) }
        observeMemory()
        observeNetwork()
        observeBattery()
        observeAudioSession()
        pushDeviceState()
    }

    /// Session identity, attached to every record from now on.
    func roomDidConnect(_ room: Room) {
        set("lk.room.sid", room.sid?.stringValue)
        set("lk.room.name", room.name)
        set("lk.participant.sid", room.localParticipant.sid?.stringValue)
        set("lk.participant.identity", room.localParticipant.identity?.stringValue)
    }

    /// Flush what the network allows (bounded), spill the rest to the cache, stop observing.
    func shutdown() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        memorySource?.cancel()
        memorySource = nil
        pathMonitor.cancel()
        for sid in _state.subscribeSpans.keys {
            endSubscribe(sid, outcome: .cancelled)
        }
        LogRelay.shared.sinks.remove(delegate: self)
        Task { @MainActor in AppStateListener.shared.delegates.remove(delegate: self) }
        let core = core
        Task { await core.shutdown() }
    }

    private func set(_ key: String, _ value: String?) {
        core.setAttribute(key: key, value: value.map { .str($0) })
    }

    // MARK: - Resource

    private static func resource() -> [LiveKitUniFFI.Attribute] {
        var attributes: [LiveKitUniFFI.Attribute] = [
            .init(key: "service.name", value: .str("livekit-client-swift")),
            .init(key: "service.version", value: .str(LiveKitSDK.version)),
            .init(key: "os.name", value: .str(String(describing: Utils.os()))),
            .init(key: "os.version", value: .str(Utils.osVersionString())),
        ]
        if let model = Utils.modelIdentifier() {
            attributes.append(.init(key: "device.model.identifier", value: .str(model)))
        }
        return attributes
    }

    // MARK: - Device state

    private func pushDeviceState() {
        let info = ProcessInfo.processInfo
        var lowPower = false
        #if os(iOS) || os(tvOS) || os(visionOS)
        lowPower = info.isLowPowerModeEnabled
        #else
        if #available(macOS 12.0, *) { lowPower = info.isLowPowerModeEnabled }
        #endif
        let state = _state.copy()
        core.setDeviceState(state: DeviceState(thermal: Self.thermal(info.thermalState),
                                               lowPowerMode: lowPower,
                                               appState: state.appState,
                                               memory: state.memory,
                                               network: state.network,
                                               networkExpensive: state.networkExpensive,
                                               networkConstrained: state.networkConstrained,
                                               batteryLevel: state.batteryLevel,
                                               batteryCharging: state.batteryCharging))
    }

    /// `DISPATCH_MEMORYPRESSURE_*`: the same source jetsam uses, on every Apple platform, and it
    /// also reports the return to normal (a memory *warning* notification does not).
    private func observeMemory() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            let pressure: MemoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            _state.mutate { $0.memory = pressure }
            pushDeviceState()
        }
        source.resume()
        memorySource = source
    }

    /// Path type plus the two flags that matter for traffic: expensive (cellular/hotspot) and
    /// constrained (Low Data Mode — the user asked for less).
    private func observeNetwork() {
        // Seed from the current path so the first state is not a spurious `unknown`.
        record(pathMonitor.currentPath)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.record(path)
            self?.pushDeviceState()
        }
        pathMonitor.start(queue: queue)
    }

    private func record(_ path: NWPath) {
        _state.mutate {
            $0.network = Self.networkType(path)
            $0.networkExpensive = path.isExpensive
            $0.networkConstrained = path.isConstrained
        }
    }

    private static func networkType(_ path: NWPath) -> NetworkType {
        guard path.status == .satisfied else { return .unavailable }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cell }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .unknown
    }

    private func observeBattery() {
        #if os(iOS) || os(visionOS)
        // ponytail: monitoring stays enabled for the process; apps toggling it themselves are unaffected.
        Task { @MainActor in
            UIDevice.current.isBatteryMonitoringEnabled = true
            self.readBattery()
        }
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            notificationTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.readBattery() }
            })
        }
        #endif
    }

    #if os(iOS) || os(visionOS)
    @MainActor private func readBattery() {
        let device = UIDevice.current
        let level = device.batteryLevel // -1 while unknown
        _state.mutate {
            $0.batteryLevel = level < 0 ? nil : UInt32((level * 100).rounded())
            $0.batteryCharging = device.batteryState == .charging || device.batteryState == .full
        }
        pushDeviceState()
    }
    #endif

    /// Route changes and interruptions are events, not state: they explain audio glitches.
    private func observeAudioSession() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) ?? .unknown
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
            self?.emit("lk.device.audio_route.changed", [
                .init(key: "lk.device.audio_route.reason", value: .str(Self.name(reason))),
                .init(key: "lk.device.audio_route.outputs", value: .str(outputs)),
            ])
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            self?.emit("lk.device.audio.interruption", [
                .init(key: "lk.device.audio.interruption", value: .str(began ? "began" : "ended")),
            ])
        })
        #endif
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    private static func name(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: "new_device_available"
        case .oldDeviceUnavailable: "old_device_unavailable"
        case .categoryChange: "category_change"
        case .override: "override"
        case .wakeFromSleep: "wake_from_sleep"
        case .noSuitableRouteForCategory: "no_suitable_route"
        case .routeConfigurationChange: "route_configuration_change"
        default: "unknown"
        }
    }
    #endif

    private func emit(_ name: String, _ attributes: [LiveKitUniFFI.Attribute]) {
        core.emit(event: TelemetryEvent(name: name, severity: .info, body: nil, attributes: attributes, spanId: nil))
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> ThermalState {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    private func setAppState(_ appState: LiveKitUniFFI.AppState) {
        _state.mutate { $0.appState = appState }
        pushDeviceState()
    }
}

// MARK: - Log records

extension RoomTelemetry: LogRecordSink {
    func receive(_ record: LogRecord) {
        // Warn/error records point at the span the emitting task runs in (connect, reconnect,
        // publish). Logs from WebRTC threads have no ambient span and stay session-level.
        let ambient = Span.current
        let spanId = (ambient?.isEnded == false) ? ambient?.context?.spanId : nil
        core.emit(event: TelemetryEvent(
            name: "",
            severity: record.level == .error ? .error : .warn,
            body: record.message,
            attributes: [
                .init(key: "code.function", value: .str(record.function)),
                .init(key: "code.file.path", value: .str(record.file)),
                .init(key: "code.line.number", value: .int(Int64(record.line))),
                .init(key: "lk.log.type", value: .str(record.type)),
            ],
            spanId: spanId,
        ))
    }
}

// MARK: - Spans

extension RoomTelemetry: SpanSink {
    func spanDidBegin(_ span: Span) {
        let kind: LiveKitUniFFI.SpanKind = span.kind == .client ? .client : .internal
        let id = core.beginSpan(name: span.label, kind: kind, parent: span.parent?.context?.spanId)
        span.context = SpanContext(traceId: core.traceId(), spanId: id)
    }

    func span(_ span: Span, didRecord entry: Span.Entry) {
        guard let id = span.context?.spanId else { return }
        core.addSpanEvent(span: id, name: entry.label, attributes: [])
    }

    func spanDidEnd(_ span: Span) {
        guard let id = span.context?.spanId else { return }
        let outcome: LiveKitUniFFI.SpanOutcome = switch span.outcome ?? .ok {
        case .ok: .ok
        case .error: .error
        case .cancelled: .cancelled
        }
        let attributes = span.attributes.map { key, value -> LiveKitUniFFI.Attribute in
            let lowered: LiveKitUniFFI.AttributeValue = switch value {
            case let .string(s): .str(s)
            case let .int(i): .int(i)
            case let .double(d): .double(d)
            case let .bool(b): .bool(b)
            }
            return .init(key: key, value: lowered)
        }
        core.endSpan(span: id, outcome: outcome, errorType: span.errorType, attributes: attributes)
    }
}

// MARK: - RTC statistics

extension RoomTelemetry: RoomDelegate {
    nonisolated func room(_: Room, participant _: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        if let track = publication.track { observe(track) }
    }

    nonisolated func room(_: Room, participant _: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        publication.track?.remove(delegate: self)
    }

    // MARK: lk.subscribe — from the intent to subscribe to the first media that arrives

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        // With autoSubscribe the intent exists the moment the track is known.
        guard room._state.connectOptions.autoSubscribe else { return }
        beginSubscribe(publication, participant: participant)
    }

    nonisolated func room(_: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        if _state.subscribeSpans[publication.sid] == nil {
            beginSubscribe(publication, participant: participant) // manual subscription
        }
        _state.subscribeSpans[publication.sid]?.record("subscribed")
        if let track = publication.track { observe(track) }
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        publication.track?.remove(delegate: self)
        endSubscribe(publication.sid, outcome: .cancelled)
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        endSubscribe(publication.sid, outcome: .cancelled)
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didFailToSubscribeTrackWithSid trackSid: Track.Sid, error: LiveKitError) {
        endSubscribe(trackSid, outcome: .error, error: error)
    }

    private func beginSubscribe(_ publication: RemoteTrackPublication, participant: RemoteParticipant) {
        guard let tracer = room?.tracer else { return }
        let sid = publication.sid
        let span = tracer.beginSpan("lk.subscribe", parent: nil)
        span.setAttribute("lk.track.sid", .string(sid.stringValue))
        span.setAttribute("lk.track.kind", .string(Span.kindName(publication.kind)))
        span.setAttribute("lk.track.source", .string(String(describing: publication.source)))
        if let identity = participant.identity?.stringValue {
            span.setAttribute("lk.participant.remote_identity", .string(identity))
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.subscribeTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.endSubscribe(sid, outcome: .error, error: LiveKitError(.timedOut, message: "No media within \(Self.subscribeTimeout)s"))
        }
        _state.mutate {
            $0.subscribeSpans[sid] = span
            $0.subscribeTimeouts[sid]?.cancel()
            $0.subscribeTimeouts[sid] = timeout
        }
    }

    private func endSubscribe(_ sid: Track.Sid, outcome: SpanOutcome, error: Error? = nil) {
        let (span, timeout) = _state.mutate {
            ($0.subscribeSpans.removeValue(forKey: sid), $0.subscribeTimeouts.removeValue(forKey: sid))
        }
        timeout?.cancel()
        span?.end(outcome: outcome, error: error)
    }

    private func observe(_ track: Track) {
        track.add(delegate: self)
        // The core windows 1 Hz readings into 15 s samples; the timer is the SDK's existing one.
        Task { await track.set(reportStatistics: true) }
    }
}

extension RoomTelemetry: TrackDelegate {
    nonisolated func track(_ track: Track, didUpdateStatistics statistics: TrackStatistics, simulcastStatistics _: [VideoCodec: TrackStatistics]) {
        for sample in Self.samples(for: track, statistics: statistics) {
            core.recordStats(sample: sample)
        }
        // First media: the subscribe span's natural end (1 s granularity, the stats timer's).
        if let sid = track.sid, _state.subscribeSpans[sid] != nil,
           statistics.inboundRtpStream.contains(where: { ($0.bytesReceived ?? 0) > 0 })
        {
            _state.subscribeSpans[sid]?.record("first_media")
            endSubscribe(sid, outcome: .ok)
        }
    }

    /// One `RtcStatsSample` per RTP stream of the track; counters pass through as reported.
    static func samples(for track: Track, statistics: TrackStatistics) -> [RtcStatsSample] {
        guard let sid = track.sid?.stringValue else { return [] }
        let kind: TrackKind
        switch track.kind {
        case .audio: kind = .audio
        case .video: kind = .video
        case .none: return []
        }
        let codecs = Dictionary(statistics.codec.map { ($0.id, $0.mimeType) }, uniquingKeysWith: { first, _ in first })
        let ms: (Double?) -> UInt64? = { $0.map { UInt64(max(0, $0) * 1000) } }

        var samples: [RtcStatsSample] = []
        for stream in statistics.inboundRtpStream {
            var sample = RtcStatsSample(trackSid: sid, kind: kind, direction: .inbound)
            sample.codec = stream.codecId.flatMap { codecs[$0] ?? nil }
            sample.bytes = stream.bytesReceived
            sample.packets = stream.packetsReceived
            sample.packetsLost = stream.packetsLost.map { UInt64(max(0, $0)) }
            sample.freezeCount = stream.freezeCount.map(UInt64.init)
            sample.freezesDurationMs = ms(stream.totalFreezesDuration)
            sample.concealedSamples = stream.concealedSamples
            sample.concealmentEvents = stream.concealmentEvents
            sample.jitterBufferDelayMs = ms(stream.jitterBufferDelay)
            sample.jitterBufferEmittedCount = stream.jitterBufferEmittedCount
            sample.jitterMs = stream.jitter.map { $0 * 1000 }
            sample.framesPerSecond = stream.framesPerSecond
            sample.audioLevel = stream.audioLevel
            samples.append(sample)
        }
        let rtt = statistics.remoteInboundRtpStream.first?.roundTripTime.map { $0 * 1000 }
        for stream in statistics.outboundRtpStream {
            var sample = RtcStatsSample(trackSid: sid, kind: kind, direction: .outbound)
            sample.codec = stream.codecId.flatMap { codecs[$0] ?? nil }
            sample.bytes = stream.bytesSent
            sample.packets = stream.packetsSent
            sample.framesPerSecond = stream.framesPerSecond
            sample.rttMs = rtt
            sample.qualityLimitationBandwidthMs = ms(stream.qualityLimitationDurations?.bandwidth)
            sample.qualityLimitationCpuMs = ms(stream.qualityLimitationDurations?.cpu)
            samples.append(sample)
        }
        return samples
    }
}

// MARK: - App state

extension RoomTelemetry: AppStateDelegate {
    func appDidEnterBackground() { setAppState(.background) }
    func appWillEnterForeground() { setAppState(.foreground) }
    func appWillTerminate() { setAppState(.background) }
    func appWillSleep() { setAppState(.background) }
    func appDidWake() { setAppState(.foreground) }
}

// MARK: - Transport

/// The host's half of the pipeline: a dumb bytes mover. The core composed URL, headers and body;
/// this only performs the POST and maps the HTTP outcome onto `ExportError` so the core decides
/// retry / drop / go-silent.
final class URLSessionTelemetryTransport: TelemetryTransport, @unchecked Sendable {
    /// Background traffic class (`NET_SERVICE_TYPE_BK`): the local stack queues it below best-effort
    /// media and signaling (fq_codel BK class, Wi-Fi AC_BK) and switches its TCP flows to LEDBAT
    /// whenever foreground traffic is active — the one knob that actually protects the uplink.
    /// Ephemeral: no cookies, no cache; one connection.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.networkServiceType = .background
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    func send(request: ExportRequest) async throws {
        guard let url = URL(string: request.url) else {
            throw ExportError.Rejected(message: "invalid url \(request.url)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let response: URLResponse
        do {
            (_, response) = try await Self.session.data(for: urlRequest)
        } catch {
            throw ExportError.Retryable(message: error.localizedDescription, retryAfterMs: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ExportError.Retryable(message: "not an HTTP response", retryAfterMs: nil)
        }
        switch http.statusCode {
        case 200 ..< 300: return
        case 429, 502, 503, 504:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { UInt64($0) }.map { $0 * 1000 }
            throw ExportError.Retryable(message: "HTTP \(http.statusCode)", retryAfterMs: retryAfter)
        default:
            throw ExportError.Rejected(message: "HTTP \(http.statusCode)")
        }
    }
}
