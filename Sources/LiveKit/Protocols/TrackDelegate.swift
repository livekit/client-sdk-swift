/*
 * Copyright 2025 LiveKit
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
public protocol TrackDelegate: AnyObject, Sendable {
    /// Dimensions of the video track has updated
    @objc(track:didUpdateDimensions:) optional
    func track(_ track: VideoTrack, didUpdateDimensions dimensions: Dimensions?)

    /// Statistics for the track has been generated (v2).
    @objc(track:didUpdateStatistics:simulcastStatistics:) optional
    func track(_ track: Track, didUpdateStatistics: TrackStatistics, simulcastStatistics: [VideoCodec: TrackStatistics])
}

protocol TrackDelegateInternal: TrackDelegate {
    /// Notify RemoteTrackPublication to send isMuted state to server.
    func track(_ track: Track, didUpdateIsMuted isMuted: Bool, shouldSendSignal: Bool)

    /// Used to report track state mutation to TrackPublication if attached.
    func track(_ track: Track, didMutateState newState: Track.State, oldState: Track.State)
}
