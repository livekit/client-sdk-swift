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
import Foundation

/// Room-scoped bridge to the Rust telemetry core (`livekit-telemetry`).
///
/// The SDK pushes what only it can observe — warn/error log records, per-track RTC statistics,
/// device state, session identity — and the core owns everything downstream: batching, RTC
/// windowing, the flood guard, the write-ahead cache, retry/backoff and the OTLP wire format.
/// Lives on ``ConnectionDependencies``: created when `connect()` starts (so pre-connect failures
/// are captured), carried across reconnects, shut down on disconnect.
final class RoomTelemetry: NSObject, @unchecked Sendable, Loggable {
    private let core: LiveKitUniFFI.Telemetry
    private var notificationTokens: [NSObjectProtocol] = []

    private struct State {
        var appState: LiveKitUniFFI.AppState = .foreground
    }

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
        core.setDeviceState(state: DeviceState(thermal: Self.thermal(info.thermalState),
                                               lowPowerMode: lowPower,
                                               appState: _state.appState))
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
        ))
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

    nonisolated func room(_: Room, participant _: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        if let track = publication.track { observe(track) }
    }

    nonisolated func room(_: Room, participant _: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        publication.track?.remove(delegate: self)
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
            (_, response) = try await URLSession.shared.data(for: urlRequest)
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
