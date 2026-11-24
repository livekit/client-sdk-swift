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

import Foundation

@objcMembers
public class LocalTrackPublication: TrackPublication, @unchecked Sendable {
    // indicates whether the track was suspended(muted) by the SDK
    var _suspended: Bool = false

    // stream state is always active for local tracks
    override public var streamState: StreamState { .active }

    public func mute() async throws {
        guard let track = track as? LocalTrack else {
            throw LiveKitError(.invalidState, message: "track is nil or not a LocalTrack")
        }

        try await track._mute()
    }

    public func unmute() async throws {
        guard let track = track as? LocalTrack else {
            throw LiveKitError(.invalidState, message: "track is nil or not a LocalTrack")
        }

        try await track._unmute()
    }

    @discardableResult
    override func set(track newValue: Track?) async -> Track? {
        let oldValue = await super.set(track: newValue)

        // listen for VideoCapturerDelegate
        if let oldLocalVideoTrack = oldValue as? LocalVideoTrack {
            oldLocalVideoTrack.capturer.remove(delegate: self)
        }

        if let newLocalVideoTrack = newValue as? LocalVideoTrack {
            newLocalVideoTrack.capturer.add(delegate: self)
        }

        return oldValue
    }
}

extension LocalTrackPublication {
    func suspend() async throws {
        // Do nothing if already muted
        guard !isMuted else { return }
        try await mute()
        _suspended = true
    }

    func resume() async throws {
        // Do nothing if was not suspended
        guard _suspended else { return }
        try await unmute()
        _suspended = false
    }
}

extension LocalTrackPublication: VideoCapturerDelegate {
    public func capturer(_: VideoCapturer, didUpdate _: Dimensions?) {
        // Native capture submits frame dimensions; sender encoding changes are not exported.
        log("Native sender encoding recomputation is not available")
    }

    public func capturer(_ capturer: VideoCapturer, didUpdate state: VideoCapturer.CapturerState) {
        guard state == .stopped, isSystemStoppable(capturer) else { return }

        Task.discarding {
            guard let participant = try await self.requireParticipant() as? LocalParticipant else {
                return
            }

            try await participant.unpublish(publication: self)
        }
    }

    /// Whether `capturer` can stop on its own, outside our disable & unpublish methods.
    ///
    /// A screen share is stoppable from system UI on both platforms, and on macOS also ends on its
    /// own when e.g. the display is powered off. The track has to be unpublished to match.
    private func isSystemStoppable(_ capturer: VideoCapturer) -> Bool {
        #if os(iOS)
        if capturer is BroadcastScreenCapturer { return true }
        #endif

        #if (os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))) && canImport(ScreenCaptureKit)
        if #available(macOS 12.3, iOS 27.0, *), capturer is ScreenCapturer { return true }
        #endif

        return false
    }
}
