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

@objc
public protocol TrackDelegate: AnyObject {
    /// Dimensions of the video track has updated
    @objc(track:didUpdateDimensions:) optional
    func track(_ track: VideoTrack, didUpdate dimensions: Dimensions?)

    /// A ``VideoView`` was attached to the ``VideoTrack``
    @objc optional
    func track(_ track: VideoTrack, didAttach videoView: VideoView)

    /// A ``VideoView`` was detached from the ``VideoTrack``
    @objc optional
    func track(_ track: VideoTrack, didDetach videoView: VideoView)

    /// ``Track/muted`` has updated.
    @objc(track:didUpdateMuted:shouldSendSignal:) optional
    func track(_ track: Track, didUpdate muted: Bool, shouldSendSignal: Bool)

    /// Statistics for the track has been generated.
    @objc(track:didUpdateStats:) optional
    func track(_ track: Track, didUpdate stats: TrackStats)
}
