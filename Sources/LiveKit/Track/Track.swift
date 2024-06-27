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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

@objc
public class Track: NSObject, Loggable {
    // MARK: - Static constants

    @objc
    public static let cameraName = "camera"

    @objc
    public static let microphoneName = "microphone"

    @objc
    public static let screenShareVideoName = "screen_share"

    @objc
    public static let screenShareAudioName = "screen_share_audio"

    // MARK: - Public types

    @objc(TrackKind)
    public enum Kind: Int, Codable {
        case audio
        case video
        case none
    }

    @objc(TrackState)
    public enum TrackState: Int, Codable {
        case stopped
        case started
    }

    @objc(TrackSource)
    public enum Source: Int, Codable {
        case unknown
        case camera
        case microphone
        case screenShareVideo
        case screenShareAudio
    }

    @objc(PublishState)
    public enum PublishState: Int {
        case unpublished
        case published
    }

    // MARK: - Public properties

    @objc
    public var kind: Kind { _state.kind }

    @objc
    public var source: Source { _state.source }

    @objc
    public var name: String { _state.name }

    @objc
    public var sid: Sid? { _state.sid }

    @objc
    public var isMuted: Bool { _state.isMuted }

    @objc
    public var statistics: TrackStatistics? { _state.statistics }

    @objc
    public var simulcastStatistics: [VideoCodec: TrackStatistics] { _state.simulcastStatistics }

    /// Dimensions of the video (only if video track)
    @objc
    public var dimensions: Dimensions? { _state.dimensions }

    /// The last video frame received for this track
    public var videoFrame: VideoFrame? { _state.videoFrame }

    @objc
    public var trackState: TrackState { _state.trackState }

    // MARK: - Internal

    let delegates = MulticastDelegate<TrackDelegate>(label: "TrackDelegate")

    let mediaTrack: LKRTCMediaStreamTrack

    struct State {
        let name: String
        let kind: Kind
        let source: Source

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

        weak var transport: Transport?
        var videoCodec: VideoCodec?
        var rtpSender: LKRTCRtpSender?
        var rtpSenderForCodec: [VideoCodec: LKRTCRtpSender] = [:] // simulcastSender
        var rtpReceiver: LKRTCRtpReceiver?

        // Weak reference to all VideoRenderers attached to this track.
        var videoRenderers = NSHashTable<VideoRenderer>.weakObjects()
    }

    let _state: StateSync<State>

    // MARK: - Private

    private let _statisticsTimer = AsyncTimer(interval: 1.0)

    init(name: String,
         kind: Kind,
         source: Source,
         track: LKRTCMediaStreamTrack,
         reportStatistics: Bool)
    {
        _state = StateSync(State(
            name: name,
            kind: kind,
            source: source,
            reportStatistics: reportStatistics
        ))

        mediaTrack = track

        super.init()

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in

            guard let self else { return }

            if oldState.dimensions != newState.dimensions {
                self.log("Track.dimensions \(String(describing: oldState.dimensions)) -> \(String(describing: newState.dimensions))")
            }

            self.delegates.notify {
                if let delegateInternal = $0 as? TrackDelegateInternal {
                    delegateInternal.track(self, didMutateState: newState, oldState: oldState)
                }
            }

            if newState.statistics != oldState.statistics || newState.simulcastStatistics != oldState.simulcastStatistics,
               let statistics = newState.statistics
            {
                self.delegates.notify { $0.track?(self, didUpdateStatistics: statistics, simulcastStatistics: newState.simulcastStatistics) }
            }
        }
    }

    func set(transport: Transport?, rtpSender: LKRTCRtpSender?) async {
        _state.mutate {
            $0.transport = transport
            $0.rtpSender = rtpSender
        }
        await _resumeOrSuspendStatisticsTimer()
    }

    func set(transport: Transport?, rtpReceiver: LKRTCRtpReceiver?) async {
        _state.mutate {
            $0.transport = transport
            $0.rtpReceiver = rtpReceiver
        }
        await _resumeOrSuspendStatisticsTimer()
    }

    private func _resumeOrSuspendStatisticsTimer() async {
        let shouldStart = _state.read {
            $0.reportStatistics && ($0.rtpSender != nil || $0.rtpReceiver != nil)
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

    @objc
    public func set(reportStatistics: Bool) async {
        _state.mutate { $0.reportStatistics = reportStatistics }
        await _resumeOrSuspendStatisticsTimer()
    }

    func set(trackState: TrackState) {
        _state.mutate { $0.trackState = trackState }
    }

    // Intended for child class to override
    func startCapture() async throws {}

    // Intended for child class to override
    func stopCapture() async throws {}

    @objc
    public final func start() async throws {
        guard _state.trackState != .started else {
            log("Already started", .warning)
            return
        }
        try await startCapture()
        if self is RemoteTrack { try await enable() }
        _state.mutate { $0.trackState = .started }
    }

    @objc
    public final func stop() async throws {
        guard _state.trackState != .stopped else {
            log("Already stopped", .warning)
            return
        }
        try await stopCapture()
        if self is RemoteTrack { try await disable() }
        _state.mutate { $0.trackState = .stopped }
    }

    // Returns true if didEnable
    @discardableResult
    func enable() async throws -> Bool {
        guard !mediaTrack.isEnabled else { return false }
        mediaTrack.isEnabled = true
        return true
    }

    // Returns true if didDisable
    @discardableResult
    func disable() async throws -> Bool {
        guard mediaTrack.isEnabled else { return false }
        mediaTrack.isEnabled = false
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
        guard self is LocalTrack else { return false }
        guard _state.publishState != .published else { return false }
        _state.mutate { $0.publishState = .published }
        return true
    }

    // Returns true if state updated
    @discardableResult
    func onUnpublish() async throws -> Bool {
        // For LocalTrack only...
        guard self is LocalTrack else { return false }
        guard _state.publishState != .unpublished else { return false }
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
        try await disable()
        try await stop()
        set(muted: true, shouldSendSignal: true)
    }

    func _unmute() async throws {
        // LocalTrack only, already un-muted
        guard self is LocalTrack, isMuted else { return }
        try await enable()
        try await start()
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
        // Read from state
        let (transport, rtpSender, rtpReceiver, simulcastRtpSenders) = _state.read { ($0.transport, $0.rtpSender, $0.rtpReceiver, $0.rtpSenderForCodec) }

        // Transport is required...
        guard let transport else { return }

        // Main statistics

        var statisticsReport: LKRTCStatisticsReport?
        let prevStatistics = _state.read { $0.statistics }

        if let sender = rtpSender {
            statisticsReport = await transport.statistics(for: sender)
        } else if let receiver = rtpReceiver {
            statisticsReport = await transport.statistics(for: receiver)
        }

        guard let statisticsReport else {
            log("statisticsReport is nil", .error)
            return
        }

        let trackStatistics = TrackStatistics(from: Array(statisticsReport.statistics.values), prevStatistics: prevStatistics)

        // Simulcast statistics

        let prevSimulcastStatistics = _state.read { $0.simulcastStatistics }
        var _simulcastStatistics: [VideoCodec: TrackStatistics] = [:]

        for _sender in simulcastRtpSenders {
            let _report = await transport.statistics(for: _sender.value)
            _simulcastStatistics[_sender.key] = TrackStatistics(from: Array(_report.statistics.values),
                                                                prevStatistics: prevSimulcastStatistics[_sender.key])
        }

        _state.mutate {
            $0.statistics = trackStatistics
            $0.simulcastStatistics = _simulcastStatistics
        }
    }
}
