import Foundation
import WebRTC

#if os(iOS)
import UIKit
#endif

// TODO: Make this internal
// Currently used for internal purposes
public protocol TrackDelegate {
    /// Dimensions of the video track has updated
    func track(_ track: VideoTrack, didUpdate dimensions: Dimensions?)
    /// Dimensions of the VideoView has updated
    func track(_ track: VideoTrack, videoView: VideoView, didUpdate size: CGSize)
    /// VideoView updated the render state
    func track(_ track: VideoTrack, videoView: VideoView, didUpdate renderState: VideoView.RenderState)
    /// A ``VideoView`` was attached to the ``VideoTrack``
    func track(_ track: VideoTrack, didAttach videoView: VideoView)
    /// A ``VideoView`` was detached from the ``VideoTrack``
    func track(_ track: VideoTrack, didDetach videoView: VideoView)
    /// ``Track/muted`` has updated.
    func track(_ track: Track, didUpdate muted: Bool, shouldSendSignal: Bool)
    /// Received a frame and should be rendered.
    func track(_ track: VideoTrack, didReceive frame: RTCVideoFrame?)
    /// Statistics for the track has been generated.
    func track(_ track: Track, didUpdate stats: TrackStats)
}

// MARK: - Optional

extension TrackDelegate {
    public func track(_ track: VideoTrack, didUpdate dimensions: Dimensions?) {}
    public func track(_ track: VideoTrack, videoView: VideoView, didUpdate size: CGSize) {}
    public func track(_ track: VideoTrack, videoView: VideoView, didUpdate renderState: VideoView.RenderState) {}
    public func track(_ track: VideoTrack, didAttach videoView: VideoView) {}
    public func track(_ track: VideoTrack, didDetach videoView: VideoView) {}
    public func track(_ track: Track, didUpdate muted: Bool, shouldSendSignal: Bool) {}
    public func track(_ track: VideoTrack, didReceive frame: RTCVideoFrame?) {}
    public func track(_ track: Track, didUpdate stats: TrackStats) {}
}
