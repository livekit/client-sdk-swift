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
import WebRTC
import Promises

@objc
public class Track: NSObject, Loggable {

    // MARK: - MulticastDelegate

    internal var delegates = MulticastDelegate<TrackDelegate>()

    internal let queue = DispatchQueue(label: "LiveKitSDK.track", qos: .default)

    @objc
    public static let cameraName = "camera"

    @objc
    public static let microphoneName = "microphone"

    @objc
    public static let screenShareVideoName = "screen_share"

    @objc
    public static let screenShareAudioName = "screen_share_audio"

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

    /// Only for ``LocalTrack``s.
    internal private(set) var _publishState: PublishState = .unpublished

    /// ``publishOptions`` used for this track if already published.
    /// Only for ``LocalTrack``s.
    internal var _publishOptions: PublishOptions?

    @objc
    public let kind: Track.Kind

    @objc
    public let source: Track.Source

    @objc
    public let name: String

    @objc
    public var sid: Sid? { _state.sid }

    @objc
    public var muted: Bool { _state.muted }

    @objc
    public var stats: TrackStats? { _state.stats }

    /// Dimensions of the video (only if video track)
    @objc
    public var dimensions: Dimensions? { _state.dimensions }

    /// The last video frame received for this track
    public var videoFrame: RTCVideoFrame? { _state.videoFrame }

    @objc
    public var trackState: TrackState { _state.trackState }

    // MARK: - Internal

    internal let mediaTrack: RTCMediaStreamTrack
    internal var transceiver: RTCRtpTransceiver?
    internal var sender: RTCRtpSender? { transceiver?.sender }

    // Weak reference to all VideoViews attached to this track. Must be accessed from main thread.
    internal var videoRenderers = NSHashTable<VideoRenderer>.weakObjects()

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
        log("sid: \(String(describing: sid))")
    }

    // returns true if updated state
    public func start() -> Promise<Bool> {

        let promise = Promise<Bool>(on: queue) { () -> Bool in

            guard self.trackState != .started else {
                // already started
                return false
            }

            self._state.mutate { $0.trackState = .started }
            return true
        }

        guard self is RemoteTrack else { return promise }

        // only for RemoteTrack
        return promise.then(on: queue) { didStart in
            self.enable().then(on: self.queue) { _ in didStart }
        }
    }

    // returns true if updated state
    public func stop() -> Promise<Bool> {

        let promise = Promise<Bool>(on: queue) { () -> Bool in

            guard self.trackState != .stopped else {
                // already stopped
                return false
            }

            self._state.mutate { $0.trackState = .stopped }
            return true
        }

        guard self is RemoteTrack else { return promise }

        return promise.then(on: queue) { didStop in
            self.disable().then(on: self.queue) { _ in didStop }
        }
    }

    internal func enable() -> Promise<Bool> {

        Promise(on: queue) { () -> Bool in

            guard !self.mediaTrack.isEnabled else {
                // already enabled
                return false
            }

            self.mediaTrack.isEnabled = true
            return true
        }
    }

    internal func disable() -> Promise<Bool> {

        Promise(on: queue) { () -> Bool in

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
            delegates.notify(label: { "track.didUpdate muted: \(newValue)" }) {
                $0.track?(self, didUpdate: newValue, shouldSendSignal: shouldSendSignal)
            }
        }
    }

    // MARK: - Local

    // returns true if state updated
    internal func onPublish() -> Promise<Bool> {
        // LocalTrack only
        guard self is LocalTrack else { return Promise(false) }

        return Promise<Bool>(on: queue) { () -> Bool in

            guard self._publishState != .published else {
                // already published
                return false
            }

            self._publishState = .published
            return true
        }
    }

    // returns true if state updated
    internal func onUnpublish() -> Promise<Bool> {
        // LocalTrack only
        guard self is LocalTrack else { return Promise(false) }

        return Promise<Bool>(on: queue) { () -> Bool in

            guard self._publishState != .unpublished else {
                // already unpublished
                return false
            }

            self._publishState = .unpublished
            return true
        }
    }
}

// MARK: - Internal

internal extension Track {

    func set(stats newValue: TrackStats) {
        guard _state.stats != newValue else { return }
        _state.mutate { $0.stats = newValue }
        delegates.notify { $0.track?(self, didUpdate: newValue) }
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

// MARK: - Local

extension Track {

    // workaround for error:
    // @objc can only be used with members of classes, @objc protocols, and concrete extensions of classes
    //
    internal func _mute() -> Promise<Void> {
        // LocalTrack only, already muted
        guard self is LocalTrack, !muted else { return Promise(()) }

        return disable().then(on: queue) { _ in
            self.stop()
        }.then(on: queue) { _ -> Void in
            self.set(muted: true, shouldSendSignal: true)
        }
    }

    internal func _unmute() -> Promise<Void> {
        // LocalTrack only, already un-muted
        guard self is LocalTrack, muted else { return Promise(()) }

        return enable().then(on: queue) { _ in
            self.start()
        }.then(on: queue) { _ -> Void in
            self.set(muted: false, shouldSendSignal: true)
        }
    }
}

// MARK: - VideoTrack

// workaround for error:
// @objc can only be used with members of classes, @objc protocols, and concrete extensions of classes
//
extension Track {

    internal func _add(videoRenderer: VideoRenderer) {

        guard self is VideoTrack, let videoTrack = self.mediaTrack as? RTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        // must always be called on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        videoRenderers.add(videoRenderer)
        videoTrack.add(videoRenderer)
    }

    internal func _remove(videoRenderer: VideoRenderer) {

        guard self is VideoTrack, let videoTrack = self.mediaTrack as? RTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        // must always be called on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        videoRenderers.remove(videoRenderer)
        videoTrack.remove(videoRenderer)
    }
}

// MARK: - MulticastDelegate

extension Track: MulticastDelegateProtocol {

    @objc(addDelegate:)
    public func add(delegate: TrackDelegate) {
        delegates.add(delegate: delegate)
    }

    @objc(removeDelegate:)
    public func remove(delegate: TrackDelegate) {
        delegates.remove(delegate: delegate)
    }

    @objc
    public func removeAllDelegates() {
        delegates.removeAllDelegates()
    }
}

// MARK: - Identifiable (SwiftUI)

extension Track: Identifiable {

    public var id: String {
        "\(type(of: self))-\(sid ?? String(hash))"
    }
}
