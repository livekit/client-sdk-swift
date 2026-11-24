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

internal import LiveKitFFI
internal import LiveKitWebRTC
import Foundation

@objcMembers
public class Track: NSObject, @unchecked Sendable, Loggable {
    // MARK: - Static constants

    public static let cameraName = "camera"

    public static let microphoneName = "microphone"

    public static let screenShareVideoName = "screen_share"

    public static let screenShareAudioName = "screen_share_audio"

    // MARK: - Public types

    @objc(TrackKind)
    public enum Kind: Int, Codable, Sendable {
        case audio
        case video
        case none
    }

    @objc(TrackState)
    public enum TrackState: Int, Codable, Sendable {
        case stopped
        case started
    }

    @objc(TrackSource)
    public enum Source: Int, Codable, Sendable {
        case unknown
        case camera
        case microphone
        case screenShareVideo
        case screenShareAudio
    }

    @objc(PublishState)
    public enum PublishState: Int, Sendable {
        case unpublished
        case published
    }

    // MARK: - Public properties

    public var kind: Kind { _state.kind }

    public var source: Source { _state.source }

    public var name: String { _state.name }

    public var sid: Sid? { _state.sid }

    public var isMuted: Bool { _state.isMuted }

    public var statistics: TrackStatistics? { _state.statistics }

    public var simulcastStatistics: [VideoCodec: TrackStatistics] { _state.simulcastStatistics }

    /// Dimensions of the video (only if video track)
    public var dimensions: Dimensions? { _state.dimensions }

    /// The last video frame received for this track
    public var videoFrame: VideoFrame? { _state.videoFrame }

    public var trackState: TrackState { _state.trackState }

    // MARK: - Internal

    let delegates = MulticastDelegate<TrackDelegate>(label: "TrackDelegate")

    let mediaTrack: RTCMediaTrack?
    let nativePublication = StateSync<NativePublicationHandle?>(nil)

    struct State {
        let name: String
        let kind: Kind
        let source: Source

        weak var nativeSession: NativeRoomSession?
        var sid: Sid?
        var dimensions: Dimensions?
        var videoFrame: VideoFrame?
        var trackState: TrackState = .stopped
        var isMuted: Bool = false
        var statistics: TrackStatistics?
        var simulcastStatistics: [VideoCodec: TrackStatistics] = [:]
        var reportStatistics: Bool = false

        // Only for LocalTracks
        var lastPublishOptions: TrackPublishOptions?
        var publishState: PublishState = .unpublished

        // All VideoRendererAdapters attached to this track, key/value for direct removal.
        var videoRendererAdapters = MapTable<VideoRenderer, VideoRendererAdapter>.weakToStrongObjects()
    }

    let _state: StateSync<State>

    // MARK: - Private

    private let _statisticsTimer = AsyncTimer(interval: 1.0)

    private let _startStopSerialRunner = SerialRunnerActor<Void>()

    init(name: String,
         kind: Kind,
         source: Source,
         track: RTCMediaTrack?,
         reportStatistics: Bool)
    {
        _state = StateSync(State(
            name: name,
            kind: kind,
            source: source,
            reportStatistics: reportStatistics,
        ))

        mediaTrack = track

        super.init()

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in
            guard let self else { return }

            if oldState.dimensions != newState.dimensions {
                log("Track.dimensions \(String(describing: oldState.dimensions)) -> \(String(describing: newState.dimensions))")
            }

            delegates.notify {
                if let delegateInternal = $0 as? TrackDelegateInternal {
                    delegateInternal.track(self, didMutateState: newState, oldState: oldState)
                }
            }

            if newState.statistics != oldState.statistics || newState.simulcastStatistics != oldState.simulcastStatistics,
               let statistics = newState.statistics
            {
                delegates.notify { $0.track?(self, didUpdateStatistics: statistics, simulcastStatistics: newState.simulcastStatistics) }
            }
        }
    }

    private func _resumeOrSuspendStatisticsTimer() async {
        let shouldStart = _state.read {
            $0.reportStatistics && nativePublication.copy() != nil
        }

        if shouldStart {
            _statisticsTimer.setTimerBlock { [weak self] in
                await self?._onStatsTimer()
            }
            _statisticsTimer.restart()
        } else {
            _statisticsTimer.cancel()
        }
    }

    public func set(reportStatistics: Bool) async {
        _state.mutate { $0.reportStatistics = reportStatistics }
        await _resumeOrSuspendStatisticsTimer()
    }

    /// Cancel the statistics timer without changing any state.
    /// The timer will restart when the track is re-attached to a transport.
    func cancelStatisticsTimer() {
        _statisticsTimer.cancel()
    }

    func set(trackState: TrackState) {
        _state.mutate { $0.trackState = trackState }
    }

    // Intended for child class to override
    func startCapture() async throws {}

    // Intended for child class to override
    func stopCapture() async throws {}

    public final func start() async throws {
        try await _startStopSerialRunner.run { [weak self] in
            guard let self else { return }
            guard _state.trackState != .started else {
                log("Already started", .warning)
                return
            }
            try await startCapture()
            if self is RemoteTrack { try await enable() }
            _state.mutate { $0.trackState = .started }
        }
    }

    public final func stop() async throws {
        try await _startStopSerialRunner.run { [weak self] in
            guard let self else { return }
            guard _state.trackState != .stopped else {
                log("Already stopped", .warning)
                return
            }
            try await stopCapture()
            if self is RemoteTrack { try await disable() }
            _state.mutate { $0.trackState = .stopped }
        }
    }

    // Returns true if didEnable
    @discardableResult
    @RTC
    func enable() async throws -> Bool {
        if let native = nativePublication.copy() {
            do { try await native.setEnabled(enabled: true) } catch { throw LiveKitError.mappingNative(error) }
            return true
        }
        guard let mediaTrack else { throw LiveKitError(.invalidState, message: "Track is not attached") }
        guard !mediaTrack.raw.isEnabled else { return false }
        mediaTrack.raw.isEnabled = true
        return true
    }

    // Returns true if didDisable
    @discardableResult
    @RTC
    func disable() async throws -> Bool {
        if let native = nativePublication.copy() {
            do { try await native.setEnabled(enabled: false) } catch { throw LiveKitError.mappingNative(error) }
            return true
        }
        guard let mediaTrack else { throw LiveKitError(.invalidState, message: "Track is not attached") }
        guard mediaTrack.raw.isEnabled else { return false }
        mediaTrack.raw.isEnabled = false
        return true
    }

    func set(muted newValue: Bool,
             notify _notify: Bool = true,
             shouldSendSignal: Bool = false)
    {
        guard _state.isMuted != newValue else { return }
        _state.mutate { $0.isMuted = newValue }

        if newValue {
            // clear video frame cache if muted
            set(videoFrame: nil)
        }

        if _notify {
            delegates.notify(label: { "track.didUpdateIsMuted: \(newValue)" }) { delegate in
                if let delegate = delegate as? TrackDelegateInternal {
                    delegate.track(self, didUpdateIsMuted: newValue, shouldSendSignal: shouldSendSignal)
                }
            }
        }
    }

    // MARK: - LocalTrack

    // Returns true if state updated
    @discardableResult
    func onPublish() async throws -> Bool {
        // For LocalTrack only...
        guard self is LocalTrack, _state.publishState != .published else { return false }
        _state.mutate { $0.publishState = .published }
        return true
    }

    // Returns true if state updated
    @discardableResult
    func onUnpublish() async throws -> Bool {
        // For LocalTrack only...
        guard self is LocalTrack, _state.publishState != .unpublished else { return false }
        _state.mutate { $0.publishState = .unpublished }
        return true
    }
}

// MARK: - Internal

extension Track {
    // returns true when value is updated
    @discardableResult
    func set(dimensions newValue: Dimensions?) -> Bool {
        guard _state.dimensions != newValue else { return false }

        _state.mutate { $0.dimensions = newValue }

        guard let videoTrack = self as? VideoTrack else { return true }
        delegates.notify(label: { "track.didUpdateDimensions: \(newValue == nil ? "nil" : String(describing: newValue))" }) {
            $0.track?(videoTrack, didUpdateDimensions: newValue)
        }

        return true
    }

    func set(videoFrame newValue: VideoFrame?) {
        guard _state.videoFrame != newValue else { return }
        _state.mutate { $0.videoFrame = newValue }
    }
}

// MARK: - Local

extension Track {
    // workaround for error:
    // @objc can only be used with members of classes, @objc protocols, and concrete extensions of classes
    //
    func _mute() async throws {
        // LocalTrack only, already muted
        guard self is LocalTrack, !isMuted else { return }
        if let native = nativePublication.copy() {
            do { try await native.setMuted(muted: true) } catch { throw LiveKitError.mappingNative(error) }
            set(muted: true)
            return
        }
        try await disable() // Disable track first
        // Only stop if VideoTrack
        if self is LocalVideoTrack {
            try await stop()
        }
        set(muted: true, shouldSendSignal: true)
    }

    func _unmute() async throws {
        // LocalTrack only, already un-muted
        guard self is LocalTrack, isMuted else { return }
        if let native = nativePublication.copy() {
            do { try await native.setMuted(muted: false) } catch { throw LiveKitError.mappingNative(error) }
            set(muted: false)
            return
        }
        // Only start if VideoTrack
        if self is LocalVideoTrack {
            try await start()
        }
        try await enable() // Enable track
        set(muted: false, shouldSendSignal: true)
    }
}

// MARK: - Identifiable (SwiftUI)

extension Track: Identifiable {
    public var id: String {
        "\(type(of: self))-\(sid?.stringValue ?? String(hash))"
    }
}

// MARK: - Stats

public extension OutboundRtpStreamStatistics {
    func formattedBps() -> String {
        format(bps: bps)
    }

    var bps: UInt64 {
        guard let previous,
              let currentBytesSent = bytesSent,
              let previousBytesSent = previous.bytesSent else { return 0 }

        // Calculate the difference in seconds, ensuring it's not zero
        let secondsDiff = (timestamp - previous.timestamp) / (1000 * 1000)
        if secondsDiff == 0 {
            // Handle the case where secondsDiff is zero to avoid division by zero
            return 0
        }

        // Calculate the rate
        let rate = Double((currentBytesSent - previousBytesSent) * 8) / abs(secondsDiff)

        // Check if the rate is a finite number before converting to UInt64
        if rate.isFinite {
            return UInt64(rate)
        } else {
            // Handle the case where rate is not finite (NaN or infinity)
            return 0
        }
    }
}

public extension InboundRtpStreamStatistics {
    func formattedBps() -> String {
        format(bps: bps)
    }

    var bps: UInt64 {
        guard let previous,
              let currentBytesReceived = bytesReceived,
              let previousBytesReceived = previous.bytesReceived else { return 0 }

        let secondsDiff = (timestamp - previous.timestamp) / (1000 * 1000)

        // Ensure secondsDiff is not zero or negative
        guard secondsDiff > 0 else { return 0 }

        // Calculate the difference in bytes received
        let bytesDiff = currentBytesReceived.subtractingReportingOverflow(previousBytesReceived)

        // Check for overflow in bytes difference
        guard !bytesDiff.overflow else { return 0 }

        // Calculate bits per second as a Double
        let bpsDouble = Double(bytesDiff.partialValue * 8) / Double(secondsDiff)

        // Ensure the result is non-negative and fits into UInt64
        guard bpsDouble >= 0, bpsDouble <= Double(UInt64.max) else { return 0 }

        return UInt64(bpsDouble)
    }
}

extension Track {
    func _onStatsTimer() async {
        guard let native = nativePublication.copy() else { return }
        do {
            let records = try await native.getStatistics()
            guard nativePublication.copy() === native else { return }
            let statistics = TrackStatistics(native: records, previous: _state.statistics)
            _state.mutate { $0.statistics = statistics }
        } catch {
            log("Native statistics sampling failed: \(error)")
        }
    }
}

extension Track {
    func detachNativeSource() async {
        cancelStatisticsTimer()
        if let audio = self as? LocalAudioTrack { audio.nativeAudio.mutate { $0 = nil } }
        if let video = self as? LocalVideoTrack {
            video.nativeCapture.mutate { $0 = nil }
            video.nativeVideo.mutate { $0 = nil }
        }
        nativePublication.mutate { $0 = nil }
        _state.mutate { $0.nativeSession = nil }
        try? await stop()
    }
}
