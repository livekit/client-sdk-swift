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

import SwiftUI

/// This class receives delegate events since a struct can't be used for a delegate
class SwiftUIVideoViewDelegateReceiver: TrackDelegate, Loggable {

    @Binding var dimensions: Dimensions?
    @Binding var stats: TrackStats?

    init(dimensions: Binding<Dimensions?> = .constant(nil),
         stats: Binding<TrackStats?> = .constant(nil)) {
        self._dimensions = dimensions
        self._stats = stats
    }

    func track(_ track: VideoTrack,
               didUpdate dimensions: Dimensions?) {
        DispatchQueue.main.async {
            self.dimensions = dimensions
        }
    }

    func track(_ track: Track, didUpdate stats: TrackStats) {
        DispatchQueue.main.async {
            self.stats = stats
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
    let preferMetal: Bool

    @Binding var dimensions: Dimensions?

    let delegateReceiver: SwiftUIVideoViewDelegateReceiver

    public init(_ track: VideoTrack,
                layoutMode: VideoView.LayoutMode = .fill,
                mirrorMode: VideoView.MirrorMode = .auto,
                dimensions: Binding<Dimensions?> = .constant(nil),
                trackStats: Binding<TrackStats?> = .constant(nil),
                preferMetal: Bool = true) {

        self.track = track
        self.layoutMode = layoutMode
        self.mirrorMode = mirrorMode
        self._dimensions = dimensions
        self.preferMetal = preferMetal

        self.delegateReceiver = SwiftUIVideoViewDelegateReceiver(dimensions: dimensions,
                                                                 stats: trackStats)

        // update binding value
        DispatchQueue.main.async {
            dimensions.wrappedValue = track.dimensions
            trackStats.wrappedValue = track.stats
        }

        // listen for TrackDelegate
        track.add(delegate: delegateReceiver)
    }

    public func makeView(context: Context) -> VideoView {
        let view = VideoView(preferMetal: preferMetal)
        updateView(view, context: context)
        return view
    }

    public func updateView(_ videoView: VideoView, context: Context) {
        videoView.track = track
        videoView.layoutMode = layoutMode
        videoView.mirrorMode = mirrorMode
        videoView.preferMetal = preferMetal
    }

    public static func dismantleView(_ videoView: VideoView, coordinator: ()) {
        videoView.track = nil
    }
}
