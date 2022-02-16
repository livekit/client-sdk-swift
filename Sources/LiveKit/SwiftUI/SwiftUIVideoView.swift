import SwiftUI

#if os(iOS)
import UIKit
public typealias NativeViewRepresentableType = UIViewRepresentable
#else
// macOS
import AppKit
public typealias NativeViewRepresentableType = NSViewRepresentable
#endif

/// This class receives delegate events since a struct can't be used for a delegate
class SwiftUIVideoViewDelegateReceiver: TrackDelegate, Loggable {

    @Binding var dimensions: Dimensions?

    init(dimensions: Binding<Dimensions?> = .constant(nil)) {
        self._dimensions = dimensions
    }

    func track(_ track: VideoTrack,
               videoView: VideoView,
               didUpdate dimensions: Dimensions) {
        log("SwiftUIVideoView received video dimensions \(dimensions)")
        DispatchQueue.main.async {
            self.dimensions = dimensions
        }
    }

    func track(_ track: VideoTrack, videoView: VideoView, didUpdate size: CGSize) {
        log("SwiftUIVideoView received view size \(size)")
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
                preferMetal: Bool = true) {

        self.track = track
        self.mode = mode
        self.mirrored = mirrored
        self._dimensions = dimensions
        self.preferMetal = preferMetal

        self.delegateReceiver = SwiftUIVideoViewDelegateReceiver(dimensions: dimensions)
        self.track.add(delegate: delegateReceiver)
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

// MARK: - NativeViewRepresentable

// multiplatform version of UI/NSViewRepresentable
protocol NativeViewRepresentable: NativeViewRepresentableType {
    /// The type of view to present.
    associatedtype ViewType: NativeView

    func makeView(context: Self.Context) -> Self.ViewType
    func updateView(_ nsView: Self.ViewType, context: Self.Context)
    static func dismantleView(_ nsView: Self.ViewType, coordinator: Self.Coordinator)
}

extension NativeViewRepresentable {

    #if os(iOS)
    public func makeUIView(context: Context) -> Self.ViewType {
        return makeView(context: context)
    }

    public func updateUIView(_ view: Self.ViewType, context: Context) {
        updateView(view, context: context)
    }

    public static func dismantleUIView(_ view: Self.ViewType, coordinator: Self.Coordinator) {
        dismantleView(view, coordinator: coordinator)
    }
    #elseif os(macOS)
    public func makeNSView(context: Context) -> Self.ViewType {
        return makeView(context: context)
    }

    public func updateNSView(_ view: Self.ViewType, context: Context) {
        updateView(view, context: context)
    }

    public static func dismantleNSView(_ view: Self.ViewType, coordinator: Self.Coordinator) {
        dismantleView(view, coordinator: coordinator)
    }
    #endif
}
