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
