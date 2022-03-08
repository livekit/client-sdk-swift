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
    let mode: VideoView.Mode
    let mirrored: Bool
    let preferMetal: Bool

    @Binding var dimensions: Dimensions?

    let delegateReceiver: SwiftUIVideoViewDelegateReceiver

    public init(_ track: VideoTrack,
                mode: VideoView.Mode = .fill,
                mirrored: Bool = false,
                dimensions: Binding<Dimensions?> = .constant(nil),
                trackStats: Binding<TrackStats?> = .constant(nil),
                preferMetal: Bool = true) {

        self.track = track
        self.mode = mode
        self.mirrored = mirrored
        self._dimensions = dimensions
        self.preferMetal = preferMetal

        self.delegateReceiver = SwiftUIVideoViewDelegateReceiver(dimensions: dimensions,
                                                                 stats: trackStats)
        self.track.add(delegate: delegateReceiver)

        // update binding value
        DispatchQueue.main.async {
            dimensions.wrappedValue = track.dimensions
            trackStats.wrappedValue = track.stats
        }
    }

    public func makeView(context: Context) -> VideoView {
        let view = VideoView(preferMetal: preferMetal)
        updateView(view, context: context)
        return view
    }

    public func updateView(_ videoView: VideoView, context: Context) {
        videoView.track = track
        videoView.mode = mode
        videoView.mirrored = mirrored
        videoView.preferMetal = preferMetal
    }

    public static func dismantleView(_ videoView: VideoView, coordinator: ()) {
        videoView.track = nil
    }
}
