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
    public var muted: Bool { _state.muted }

    @objc
    public var statistics: TrackStatistics? { _state.statistics }

    /// Dimensions of the video (only if video track)
    @objc
    public var dimensions: Dimensions? { _state.dimensions }

    /// The last video frame received for this track
    public var videoFrame: VideoFrame? { _state.videoFrame }

    @objc
    public var trackState: TrackState { _state.trackState }

    // MARK: - Internal

    internal var delegates = MulticastDelegate<TrackDelegate>()

    internal let queue = DispatchQueue(label: "LiveKitSDK.track", qos: .default)

    /// Only for ``LocalTrack``s.
    internal private(set) var _publishState: PublishState = .unpublished

    /// ``publishOptions`` used for this track if already published.
    /// Only for ``LocalTrack``s.
    internal var _publishOptions: PublishOptions?

    internal let mediaTrack: LKRTCMediaStreamTrack

    internal private(set) var rtpSender: LKRTCRtpSender?
    internal private(set) var rtpReceiver: LKRTCRtpReceiver?

    // Weak reference to all VideoViews attached to this track. Must be accessed from main thread.
    internal var videoRenderers = NSHashTable<VideoRenderer>.weakObjects()
    // internal var rtcVideoRenderers = NSHashTable<RTCVideoRenderer>.weakObjects()

    internal struct State: Equatable {
        let name: String
        let kind: Kind
        let source: Source

        var sid: Sid?
        var dimensions: Dimensions?
        var videoFrame: VideoFrame?
        var trackState: TrackState = .stopped
        var muted: Bool = false
        var statistics: TrackStatistics?
        var reportStatistics: Bool = false
    }

    internal var _state: StateSync<State>

    // MARK: - Private

    private weak var transport: Transport?
    private let statisticsTimer = DispatchQueueTimer(timeInterval: 1, queue: .liveKitWebRTC)

    internal init(name: String,
                  kind: Kind,
                  source: Source,
                  track: LKRTCMediaStreamTrack) {

        _state = StateSync(State(
            name: name,
            kind: kind,
            source: source
        ))

        mediaTrack = track

        super.init()

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in

            guard let self = self else { return }

            if oldState.dimensions != newState.dimensions {
                log("Track.dimensions \(String(describing: oldState.dimensions)) -> \(String(describing: newState.dimensions))")
            }

            self.delegates.notify {
                if let delegateInternal = $0 as? TrackDelegateInternal {
                    delegateInternal.track(self, didMutateState: newState, oldState: oldState)
                }
            }

            if newState.statistics != oldState.statistics, let statistics = newState.statistics {
                self.delegates.notify { $0.track?(self, didUpdateStatistics: statistics) }
            }
        }

        statisticsTimer.handler = { [weak self] in
            self?.onStatsTimer()
        }
    }

    deinit {
        statisticsTimer.suspend()
        log("sid: \(String(describing: sid))")
    }

    internal func set(transport: Transport, rtpSender: LKRTCRtpSender) {
        self.transport = transport
        self.rtpSender = rtpSender
        resumeOrSuspendStatisticsTimer()
    }

    internal func set(transport: Transport, rtpReceiver: LKRTCRtpReceiver) {
        self.transport = transport
        self.rtpReceiver = rtpReceiver
        resumeOrSuspendStatisticsTimer()
    }

    internal func resumeOrSuspendStatisticsTimer() {
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

    // Returns true if didStart
    @objc
    @discardableResult
    public func start() async throws -> Bool {
        guard trackState != .started else { return false }
        _state.mutate { $0.trackState = .started }
        if self is RemoteTrack { try await enable() }
        return true
    }

    // Returns true if didStop
    @objc
    @discardableResult
    public func stop() async throws -> Bool {
        guard trackState != .stopped else { return false }
        _state.mutate { $0.trackState = .stopped }
        if self is RemoteTrack { try await disable() }
        return true
    }

    // Returns true if didEnable
    @discardableResult
    internal func enable() async throws -> Bool {
        guard !mediaTrack.isEnabled else { return false }
        mediaTrack.isEnabled = true
        return true
    }

    // Returns true if didDisable
    @discardableResult
    internal func disable() async throws -> Bool {
        guard mediaTrack.isEnabled else { return false }
        mediaTrack.isEnabled = false
        return true
    }

    internal func set(muted newValue: Bool,
                      notify _notify: Bool = true,
                      shouldSendSignal: Bool = false) {

        guard _state.muted != newValue else { return }
        _state.mutate { $0.muted = newValue }

        if newValue {
            // clear video frame cache if muted
            set(videoFrame: nil)
        }

        if _notify {
            delegates.notify(label: { "track.didUpdate muted: \(newValue)" }) {
                $0.track?(self, didUpdate: newValue, shouldSendSignal: shouldSendSignal)
            }
        }
    }

    // MARK: - LocalTrack

    // Returns true if state updated
    @discardableResult
    internal func onPublish() async throws -> Bool {
        // For LocalTrack only...
        guard self is LocalTrack else { return false }
        guard self._publishState != .published else { return false }
        self._publishState = .published
        return true
    }

    // Returns true if state updated
    @discardableResult
    internal func onUnpublish() async throws -> Bool {
        // For LocalTrack only...
        guard self is LocalTrack else { return false }
        guard self._publishState != .unpublished else { return false }
        self._publishState = .unpublished
        return true
    }
}

// MARK: - Internal

internal extension Track {

    // returns true when value is updated
    @discardableResult
    func set(dimensions newValue: Dimensions?) -> Bool {

        guard _state.dimensions != newValue else { return false }

        _state.mutate { $0.dimensions = newValue }

        guard let videoTrack = self as? VideoTrack else { return true }
        delegates.notify(label: { "track.didUpdate dimensions: \(newValue == nil ? "nil" : String(describing: newValue))" }) {
            $0.track?(videoTrack, didUpdate: newValue)
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
    internal func _mute() async throws {
        // LocalTrack only, already muted
        guard self is LocalTrack, !muted else { return }
        try await disable()
        try await stop()
        set(muted: true, shouldSendSignal: true)
    }

    internal func _unmute() async throws {
        // LocalTrack only, already un-muted
        guard self is LocalTrack, muted else { return }
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

    internal func _add(videoRenderer: VideoRenderer) {

        guard self is VideoTrack, let rtcVideoTrack = self.mediaTrack as? LKRTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        // must always be called on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        videoRenderers.add(videoRenderer)
        rtcVideoTrack.add(VideoRendererAdapter(target: videoRenderer))
    }

    internal func _remove(videoRenderer: VideoRenderer) {

        guard self is VideoTrack, let rtcVideoTrack = self.mediaTrack as? LKRTCVideoTrack else {
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
        guard let previous = previous,
              let currentBytesSent = bytesSent,
              let previousBytesSent = previous.bytesSent else { return 0 }
        let secondsDiff = (timestamp - previous.timestamp) / (1000 * 1000)
        return UInt64(Double(((currentBytesSent - previousBytesSent) * 8)) / abs(secondsDiff))
    }
}

public extension InboundRtpStreamStatistics {

    func formattedBps() -> String {
        format(bps: bps)
    }

    var bps: UInt64 {
        guard let previous = previous,
              let currentBytesReceived = bytesReceived,
              let previousBytesReceived = previous.bytesReceived else { return 0 }
        let secondsDiff = (timestamp - previous.timestamp) / (1000 * 1000)
        return UInt64(Double(((currentBytesReceived - previousBytesReceived) * 8)) / abs(secondsDiff))
    }
}

extension Track {

    func onStatsTimer() {

        guard let transport = transport else { return }

        statisticsTimer.suspend()

        Task {

            defer { statisticsTimer.resume() }

            var statisticsReport: LKRTCStatisticsReport?
            let prevStatistics = _state.read { $0.statistics }

            if let sender = rtpSender {
                statisticsReport = await transport.statistics(for: sender)
            } else if let receiver = rtpReceiver {
                statisticsReport = await transport.statistics(for: receiver)
            }

            assert(statisticsReport != nil, "statisticsReport is nil")
            guard let statisticsReport = statisticsReport else { return }

            let trackStatistics = TrackStatistics(from: Array(statisticsReport.statistics.values), prevStatistics: prevStatistics)

            _state.mutate { $0.statistics = trackStatistics }
        }
    }
}
