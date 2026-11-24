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

internal import LiveKitFFI
internal import LiveKitWebRTC
import Foundation

/// Client telemetry. The pipeline — destination, token, batching, retries, cache, holds, stats
/// mapping, span state — lives in the Rust core, one per process; Swift installs it, feeds it OS
/// signals and moves its bytes. Every tuning value is the core's default.
enum Telemetry {
    /// A new Room's scope, installing the pipeline first if this is the first Room; none after the opt-out.
    static func scope() -> TelemetryScope? {
        _ = installed
        return telemetryScope()
    }

    /// Opt-out, in effect when this returns: no scope, no capture, configures refused; the core
    /// purges what it holds in the background. A cache left by an earlier launch belongs to no
    /// pipeline yet: the clean-up's refused configure deletes it, off the caller's thread.
    static func disable() {
        disabled.mutate { $0 = true } // released before calling the core: never held across it
        telemetryDisable()
        for rtc in rtcInstruments.read({ $0.allObjects }) {
            rtc.stop()
        }
        cleanUp()
    }

    /// Owns the opt-out's clean-up: one refused configure, which waits for the core's purge and
    /// then deletes ``storageDirectory`` (a failure stays with the core for a later opt-out). It
    /// blocks while it runs, so it runs here, never on the caller; at most once per process.
    static let cleanUpQueue = DispatchQueue(label: "LiveKitSDK.telemetry.cleanup", qos: .utility)
    private static let cleanUpScheduled = StateSync(false)

    /// Test seam: runs on ``cleanUpQueue`` right before the refused configure.
    static let beforeCleanUp = StateSync<(@Sendable () -> Void)?>(nil)

    /// Test seam: runs on the caller that scheduled the clean-up, after it let go of the lock.
    static let afterCleanUpScheduled = StateSync<(@Sendable () -> Void)?>(nil)

    /// Marks and queues the clean-up in one locked step, so a caller that finds it marked also
    /// finds it queued. Queueing never blocks; the configure runs later, outside the lock.
    private static func cleanUp() {
        let scheduled = cleanUpScheduled.mutate { scheduled in
            guard !scheduled else { return false }
            scheduled = true
            cleanUpQueue.async {
                beforeCleanUp.copy()?()
                install()
            }
            return true
        }
        if scheduled { afterCleanUpScheduled.copy()?() }
    }

    /// Returns once the opt-out's clean-up has run; at once when none was scheduled. Queued under
    /// the scheduling lock, so it lands behind any clean-up that a concurrent opt-out marked.
    static func cleanUpFinished() async {
        await withCheckedContinuation { continuation in
            cleanUpScheduled.read { _ in cleanUpQueue.async { continuation.resume() } }
        }
    }

    /// Set by ``disable()``: the Rooms' RTC instruments, which the core does not own, check it too.
    static let disabled = StateSync(false)

    /// Runs `start` only while collecting, holding the opt-out lock across the check and `start`,
    /// so nothing starts once ``disable()`` has returned. `start` must be synchronous and short
    /// (it only initiates) and must not call back into this lock.
    static func ifCollecting(_ start: () -> Void) -> Bool {
        disabled.read { optedOut in
            guard !optedOut else { return false }
            start()
            return true
        }
    }

    /// The stats poll's steps that ``ifCollecting(_:)`` admits.
    enum GatedStep { case request, submit }

    /// Test seam: awaited right before each gated step, in tasks that bind it.
    @TaskLocal static var beforeGate: (@Sendable (GatedStep) async -> Void)?

    /// Every live Room's RTC instrument, so the opt-out stops their polling at once.
    static let rtcInstruments = StateSync(NSHashTable<RTCTelemetry>.weakObjects())

    /// Installed synchronously on first use, so a Room never misses its scope.
    private static let installed: Void = configure()

    /// Install the process pipeline; after the opt-out, the clean-up instead. A configure racing
    /// the opt-out can still reach the core after it and wait there for the refusal.
    static func configure() {
        guard !disabled.copy() else { return cleanUp() }
        install()
    }

    /// The core's configure: installs, or after the opt-out refuses and erases `storageDir`.
    private static func install() {
        let sdk = TelemetryResource(sdk: .swift,
                                    sdkVersion: LiveKitSDK.version,
                                    osName: String(describing: Utils.os()),
                                    osVersion: Utils.osVersionString(),
                                    deviceModel: Utils.modelIdentifier())
        let storage = storageDirectory
        if !disabled.copy(), let parent = storage?.deletingLastPathComponent() {
            // The core creates the directory, not its parent: without one it caches in memory only.
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let config = TelemetryConfig(sdk: sdk, storageDir: storage?.path)
        // Fail-open: the app runs without telemetry rather than not at all.
        try? telemetryConfigure(config: config, transport: URLSessionTelemetryTransport(), instruments: [DeviceTelemetry(), WebRTCLogCapture()])
    }

    /// `Caches/livekit-telemetry/<app>`: purgeable and never backed up; per app, since the Caches
    /// directory of an unsandboxed macOS process is shared by every app of that user.
    static var storageDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("livekit-telemetry", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, isDirectory: true)
    }

    /// An SDK warning or error, filed under the ambient span, else the emitter's Room, else the process.
    static func log(_ record: LogRecord, scope: TelemetryScope?) {
        var record = record
        record.spanId = TelemetrySpan.current.flatMap { $0.isEnded() ? nil : $0.context()?.spanId }
        if record.spanId == nil, let scope {
            scope.log(record: record)
        } else {
            telemetryLog(record: record)
        }
    }
}

// MARK: - Ambient span

extension TelemetrySpan {
    /// The span the current task works inside: child spans nest under it and warn/error records
    /// point at it. Bound around connect, a reconnect cycle and publish.
    @TaskLocal static var current: TelemetrySpan?

    /// End on a Swift error: `cancelled` for a cancellation, `error` otherwise.
    func end(with error: Error) {
        if error is CancellationError || (error as? LiveKitError)?.type == .cancelled {
            cancel()
        } else {
            fail(error: Self.errorType(error))
        }
    }

    /// `error.type`: `LiveKitError.<code>` (its `description` is prose, not the case), else the
    /// Swift type name.
    static func errorType(_ error: Error) -> String {
        if let error = error as? LiveKitError { return "LiveKitError.\(error.type.rawValue)" }
        return String(describing: type(of: error))
    }
}

// MARK: - Log capture

/// WebRTC's own errors: one sink of its own, next to (never instead of) the app's console logger.
/// Unchecked: `LKRTCCallbackLogger` is not `Sendable`, but the core calls `start` once and `stop`
/// once per pipeline, and nothing else touches the logger.
final class WebRTCLogCapture: TelemetryInstrument, @unchecked Sendable {
    private let logger = LKRTCCallbackLogger()
    private let capturing = StateSync(true)

    func start() {
        logger.severity = .error
        logger.start { [capturing] message in
            guard capturing.copy() else { return }
            telemetryLog(record: LogRecord(severity: .error, source: .webRtc,
                                           body: message.trimmingCharacters(in: .whitespacesAndNewlines),
                                           logger: "WebRTC"))
        }
    }

    /// Called by the core on the caller's thread under its lifecycle lock: flag and return. The
    /// sink goes later, off that thread, since removing it waits on WebRTC's log lock, which a
    /// WebRTC thread may hold while its callback waits on the core.
    func stop() {
        capturing.mutate { $0 = false }
        DispatchQueue.global(qos: .utility).async { self.logger.stop() }
    }
}

// MARK: - Shared vocabulary

extension LogLevel {
    var severity: Severity {
        switch self {
        case .debug: .debug
        case .info: .info
        case .warning: .warn
        case .error: .error
        }
    }
}

extension SpanStep {
    /// A ``Span`` entry label as the core's checkpoint; labels it has no type for stay custom.
    init(_ label: String) {
        self = switch label {
        case "ws_open": .wsOpen
        case "signal": .signal
        case "join_recv": .joinRecv
        case "pc_created": .pcCreated
        case "offer_sent": .offerSent
        case "answer_sent": .answerSent
        case "engine": .engine
        case "pc_connected": .pcConnected
        case "room_connected": .roomConnected
        default: .custom(name: label)
        }
    }
}

extension StartReconnectReason {
    var telemetry: TelemetryReconnectReason {
        switch self {
        case .websocket: .signalDisconnected
        case .transport: .transportFailed
        case .networkSwitch: .networkChanged
        case .debug: .debug
        }
    }
}

extension SpanTrack {
    init?(_ track: Track) {
        guard let kind = TrackKind(track.kind) else { return nil }
        self.init(sid: track.sid?.stringValue, kind: kind, source: TrackSource(track.source))
    }

    init?(_ publication: TrackPublication, remoteIdentity: String?) {
        guard let kind = TrackKind(publication.kind) else { return nil }
        self.init(sid: publication.sid.stringValue, kind: kind, source: TrackSource(publication.source), remoteIdentity: remoteIdentity)
    }
}

extension TrackKind {
    init?(_ kind: Track.Kind) {
        switch kind {
        case .audio: self = .audio
        case .video: self = .video
        default: return nil
        }
    }
}

extension TrackSource {
    init(_ source: Track.Source) {
        self = switch source {
        case .camera: .camera
        case .microphone: .microphone
        case .screenShareVideo: .screenShare
        case .screenShareAudio: .screenShareAudio
        case .unknown: .unknown
        }
    }
}

extension CaptureFailure {
    /// A publish error that says the capture device failed, if it does.
    init?(_ error: Error) {
        guard let error = error as? LiveKitError else { return nil }
        switch error.type {
        case .deviceAccessDenied: self = .permissionDenied
        case .deviceNotFound: self = .notFound
        case .captureFormatNotFound, .unableToResolveFPSRange, .capturerDimensionsNotResolved, .audioEngine: self = .other
        default: return nil
        }
    }
}

extension CaptureDevice {
    init?(_ source: Track.Source) {
        switch source {
        case .camera: self = .camera
        case .microphone: self = .microphone
        case .screenShareVideo: self = .screenShare
        default: return nil
        }
    }
}

extension DisconnectReason {
    /// The error a Room's clean-up was given; none is the app's own `disconnect()`.
    init(_ error: Error?) {
        guard let error else { self = .clientInitiated; return }
        self = switch (error as? LiveKitError)?.type {
        case .cancelled: .clientInitiated
        case .duplicateIdentity: .duplicateIdentity
        case .serverShutdown: .serverShutdown
        case .participantRemoved: .participantRemoved
        case .roomDeleted: .roomDeleted
        case .stateMismatch: .stateMismatch
        case .joinFailure: .joinFailure
        case .timedOut, .serverPingTimedOut: .connectionTimeout
        default: .unknown
        }
    }
}

/// Something that belongs to a Room: its warnings and errors land in that Room's trace.
protocol TelemetryScoped {
    var telemetryScope: TelemetryScope? { get }
}

extension Room: TelemetryScoped {}

extension Participant: TelemetryScoped {
    var telemetryScope: TelemetryScope? { _room?.telemetryScope }
}
