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

// TODO: Make this internal
// Currently used for internal purposes
public protocol TrackDelegate: AnyObject {
    /// Dimensions of the video track has updated
    func track(_ track: VideoTrack, didUpdate dimensions: Dimensions?)
    /// Dimensions of the VideoView has updated
    func track(_ track: VideoTrack, videoView: VideoView, didUpdate size: CGSize)
    /// VideoView updated the isRendering property
    func track(_ track: VideoTrack, videoView: VideoView, didUpdate isRendering: Bool)
    /// A ``VideoView`` was attached to the ``VideoTrack``
    func track(_ track: VideoTrack, didAttach videoView: VideoView)
    /// A ``VideoView`` was detached from the ``VideoTrack``
    func track(_ track: VideoTrack, didDetach videoView: VideoView)
    /// ``Track/muted`` has updated.
    func track(_ track: Track, didUpdate muted: Bool, shouldSendSignal: Bool)
    /// Statistics for the track has been generated.
    func track(_ track: Track, didUpdate stats: TrackStats)
}

// MARK: - Optional

extension TrackDelegate {
    public func track(_ track: VideoTrack, didUpdate dimensions: Dimensions?) {}
    public func track(_ track: VideoTrack, videoView: VideoView, didUpdate size: CGSize) {}
    public func track(_ track: VideoTrack, videoView: VideoView, didUpdate isRendering: Bool) {}
    public func track(_ track: VideoTrack, didAttach videoView: VideoView) {}
    public func track(_ track: VideoTrack, didDetach videoView: VideoView) {}
    public func track(_ track: Track, didUpdate muted: Bool, shouldSendSignal: Bool) {}
    public func track(_ track: Track, didUpdate stats: TrackStats) {}
}
