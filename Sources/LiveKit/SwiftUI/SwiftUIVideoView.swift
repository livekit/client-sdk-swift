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
import SwiftUI

/// This class receives ``TrackDelegate`` events since a struct can't be used for a delegate
internal class TrackDelegateReceiver: TrackDelegate, Loggable {

    @Binding var dimensions: Dimensions?
    @Binding var stats: TrackStats?

    init(dimensions: Binding<Dimensions?>, stats: Binding<TrackStats?>) {
        self._dimensions = dimensions
        self._stats = stats
    }

    func track(_ track: VideoTrack, didUpdate dimensions: Dimensions?) {
        Task.detached { @MainActor in
            self.dimensions = dimensions
        }
    }

    func track(_ track: Track, didUpdate stats: TrackStats) {
        Task.detached { @MainActor in
            self.stats = stats
        }
    }
}

/// This class receives ``VideoViewDelegate`` events since a struct can't be used for a delegate
internal class VideoViewDelegateReceiver: VideoViewDelegate, Loggable {

    @Binding var isRendering: Bool

    init(isRendering: Binding<Bool>) {
        self._isRendering = isRendering
    }

    func videoView(_ videoView: VideoView, didUpdate isRendering: Bool) {
        Task.detached { @MainActor in
            self.isRendering = isRendering
        }
    }
}

/// A ``VideoView`` that can be used in SwiftUI.
/// Supports both iOS and macOS.
public struct SwiftUIVideoView: NativeViewRepresentable {

    typealias ViewType = VideoView

    /// Pass a ``VideoTrack`` of a ``Participant``.
    let track: VideoTrack
    let layoutMode: VideoView.LayoutMode
    let mirrorMode: VideoView.MirrorMode
    let debugMode: Bool

    @Binding var isRendering: Bool
    @Binding var dimensions: Dimensions?

    let trackDelegateReceiver: TrackDelegateReceiver
    let videoViewDelegateReceiver: VideoViewDelegateReceiver

    public init(_ track: VideoTrack,
                layoutMode: VideoView.LayoutMode = .fill,
                mirrorMode: VideoView.MirrorMode = .auto,
                debugMode: Bool = false,
                isRendering: Binding<Bool> = .constant(false),
                dimensions: Binding<Dimensions?> = .constant(nil),
                trackStats: Binding<TrackStats?> = .constant(nil)) {

        self.track = track
        self.layoutMode = layoutMode
        self.mirrorMode = mirrorMode
        self.debugMode = debugMode

        self._isRendering = isRendering
        self._dimensions = dimensions

        self.trackDelegateReceiver = TrackDelegateReceiver(dimensions: dimensions,
                                                           stats: trackStats)

        self.videoViewDelegateReceiver = VideoViewDelegateReceiver(isRendering: isRendering)

        // update binding value
        Task.detached { @MainActor in
            dimensions.wrappedValue = track.dimensions
            trackStats.wrappedValue = track.stats
        }

        // listen for TrackDelegate
        track.add(delegate: trackDelegateReceiver)
    }

    public func makeView(context: Context) -> VideoView {
        let view = VideoView()
        view.add(delegate: videoViewDelegateReceiver)
        updateView(view, context: context)
        return view
    }

    public func updateView(_ videoView: VideoView, context: Context) {
        videoView.track = track
        videoView.layoutMode = layoutMode
        videoView.mirrorMode = mirrorMode
        videoView.debugMode = debugMode

        // update
        Task.detached { @MainActor in
            self.isRendering = videoView.isRendering
        }
    }

    public static func dismantleView(_ videoView: VideoView, coordinator: ()) {
        videoView.track = nil
    }
}
