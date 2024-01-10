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

    public let delegates = MulticastDelegate<TrackDelegate>()

    /// Only for ``LocalTrack``s.
    private(set) var _publishState: PublishState = .unpublished

    /// ``publishOptions`` used for this track if already published.
    /// Only for ``LocalTrack``s.
    var _publishOptions: PublishOptions?

    let mediaTrack: LKRTCMediaStreamTrack

    private(set) var rtpSender: LKRTCRtpSender?
    private(set) var rtpReceiver: LKRTCRtpReceiver?

    var _videoCodec: VideoCodec?
    var _simulcastRtpSenders: [VideoCodec: LKRTCRtpSender] = [:]

    // Weak reference to all VideoViews attached to this track. Must be accessed from main thread.
    var videoRenderers = NSHashTable<VideoRenderer>.weakObjects()
    // internal var rtcVideoRenderers = NSHashTable<RTCVideoRenderer>.weakObjects()

    struct State: Equatable {
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
    }

    var _state: StateSync<State>

    // MARK: - Private

    private weak var transport: Transport?
    private let statisticsTimer = DispatchQueueTimer(timeInterval: 1, queue: .liveKitWebRTC)

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

        statisticsTimer.handler = { [weak self] in
            self?.onStatsTimer()
        }

        resumeOrSuspendStatisticsTimer()
    }

    deinit {
        statisticsTimer.suspend()
        log("sid: \(String(describing: sid))")
    }

    func set(transport: Transport?, rtpSender: LKRTCRtpSender?) {
        self.transport = transport
        self.rtpSender = rtpSender
        resumeOrSuspendStatisticsTimer()
    }

    func set(transport: Transport?, rtpReceiver: LKRTCRtpReceiver?) {
        self.transport = transport
        self.rtpReceiver = rtpReceiver
        resumeOrSuspendStatisticsTimer()
    }

    func resumeOrSuspendStatisticsTimer() {
        if _state.reportStatistics, rtpSender != nil || rtpReceiver != nil {
            statisticsTimer.resume()
        } else {
            statisticsTimer.suspend()
        }
    }

    @objc
    public func set(reportStatistics: Bool) {
        _state.mutate { $0.reportStatistics = reportStatistics }
        resumeOrSuspendStatisticsTimer()
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
        guard _publishState != .published else { return false }
        _publishState = .published
        return true
    }

    // Returns true if state updated
    @discardableResult
    func onUnpublish() async throws -> Bool {
        // For LocalTrack only...
        guard self is LocalTrack else { return false }
        guard _publishState != .unpublished else { return false }
        _publishState = .unpublished
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

// MARK: - VideoTrack

// workaround for error:
// @objc can only be used with members of classes, @objc protocols, and concrete extensions of classes
//
extension Track {
    func _add(videoRenderer: VideoRenderer) {
        guard self is VideoTrack, let rtcVideoTrack = mediaTrack as? LKRTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        // must always be called on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        videoRenderers.add(videoRenderer)
        rtcVideoTrack.add(VideoRendererAdapter(target: videoRenderer))
    }

    func _remove(videoRenderer: VideoRenderer) {
        guard self is VideoTrack, let rtcVideoTrack = mediaTrack as? LKRTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        // must always be called on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        videoRenderers.remove(videoRenderer)
        rtcVideoTrack.remove(VideoRendererAdapter(target: videoRenderer))
    }
}

// MARK: - Identifiable (SwiftUI)

extension Track: Identifiable {
    public var id: String {
        "\(type(of: self))-\(sid ?? String(hash))"
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
        return UInt64(Double((currentBytesReceived - previousBytesReceived) * 8) / abs(secondsDiff))
    }
}

extension Track {
    func onStatsTimer() {
        guard let transport else { return }

        statisticsTimer.suspend()

        Task {
            defer { statisticsTimer.resume() }

            // Main tatistics

            var statisticsReport: LKRTCStatisticsReport?
            let prevStatistics = _state.read { $0.statistics }

            if let sender = rtpSender {
                statisticsReport = await transport.statistics(for: sender)
            } else if let receiver = rtpReceiver {
                statisticsReport = await transport.statistics(for: receiver)
            }

            assert(statisticsReport != nil, "statisticsReport is nil")
            guard let statisticsReport else { return }

            let trackStatistics = TrackStatistics(from: Array(statisticsReport.statistics.values), prevStatistics: prevStatistics)

            // Simulcast statistics

            let prevSimulcastStatistics = _state.read { $0.simulcastStatistics }
            var _simulcastStatistics: [VideoCodec: TrackStatistics] = [:]
            for _sender in _simulcastRtpSenders {
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
}
