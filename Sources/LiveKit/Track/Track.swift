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

import WebRTC
import Promises

struct WeakContainer<Object: AnyObject> {
    weak var weakObject: Object?
}

extension Array where Element == WeakContainer<VideoView> {

    var allObjects: [VideoView] {
        compactMap { $0.weakObject }
    }

    func contains(weakElement: VideoView) -> Bool {
        contains(where: { $0.weakObject == weakElement })
    }

    mutating func add(weakElement: VideoView) {
        guard !contains(weakElement: weakElement) else { return }
        append(WeakContainer(weakObject: weakElement))
    }

    mutating func remove(weakElement: VideoView) {
        removeAll { $0.weakObject == weakElement }
    }
}

public class Track: MulticastDelegate<TrackDelegate> {

    public static let cameraName = "camera"
    public static let microphoneName = "microphone"
    public static let screenShareVideoName = "screen_share"
    public static let screenShareAudioName = "screen_share_audio"

    public enum Kind {
        case audio
        case video
        case none
    }

    public enum TrackState {
        case stopped
        case started
    }

    public enum Source {
        case unknown
        case camera
        case microphone
        case screenShareVideo
        case screenShareAudio
    }

    public let kind: Track.Kind
    public let source: Track.Source
    public let name: String

    public var sid: Sid? { _state.sid }
    public var muted: Bool { _state.muted }
    public var stats: TrackStats? { _state.stats }

    /// Dimensions of the video (only if video track)
    public var dimensions: Dimensions? { _state.dimensions }

    /// The last video frame received for this track
    public var videoFrame: RTCVideoFrame? { _state.videoFrame }
    public var trackState: TrackState { _state.trackState }

    // MARK: - Internal

    internal let mediaTrack: RTCMediaStreamTrack
    internal var transceiver: RTCRtpTransceiver?
    internal var sender: RTCRtpSender? { transceiver?.sender }

    // must be on main thread
    internal var videoViews = [WeakContainer<VideoView>]()

    internal struct State {
        var sid: Sid?
        var dimensions: Dimensions?
        var videoFrame: RTCVideoFrame?
        var trackState: TrackState = .stopped
        var muted: Bool = false
        var stats: TrackStats?
    }

    internal var _state = StateSync(State())

    internal init(name: String, kind: Kind, source: Source, track: RTCMediaStreamTrack) {
        self.name = name
        self.kind = kind
        self.source = source
        mediaTrack = track
    }

    deinit {
        log()
    }

    // returns true if updated state
    public func start() -> Promise<Bool> {

        Promise(on: .sdk) { () -> Bool in

            guard self.trackState != .started else {
                // already started
                return false
            }

            self._state.mutate { $0.trackState = .started }
            return true
        }
    }

    // returns true if updated state
    public func stop() -> Promise<Bool> {

        Promise(on: .sdk) { () -> Bool in

            guard self.trackState != .stopped else {
                // already stopped
                return false
            }

            self._state.mutate { $0.trackState = .stopped }
            return true
        }
    }

    internal func enable() -> Promise<Bool> {

        Promise(on: .sdk) { () -> Bool in

            guard !self.mediaTrack.isEnabled else {
                // already enabled
                return false
            }

            self.mediaTrack.isEnabled = true
            return true
        }
    }

    internal func disable() -> Promise<Bool> {

        Promise(on: .sdk) { () -> Bool in

            guard self.mediaTrack.isEnabled else {
                // already disabled
                return false
            }

            self.mediaTrack.isEnabled = false
            return true
        }
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
            notify { $0.track(self, didUpdate: newValue, shouldSendSignal: shouldSendSignal) }
        }
    }
}

// MARK: - Internal

internal extension Track {

    func set(stats newValue: TrackStats) {
        guard _state.stats != newValue else { return }
        _state.mutate { $0.stats = newValue }
        notify { $0.track(self, didUpdate: newValue) }
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
        notify { $0.track(videoTrack, didUpdate: newValue) }

        return true
    }

    func set(videoFrame newValue: RTCVideoFrame?) {
        guard _state.videoFrame != newValue else { return }

        _state.mutate { $0.videoFrame = newValue }
    }
}

// MARK: - Deprecated

extension Track {

    @available(*, deprecated, renamed: "trackState")
    public var state: TrackState {
        self._state.trackState
    }
}
