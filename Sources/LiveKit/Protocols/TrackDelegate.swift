import Foundation

#if os(iOS)
import UIKit
#endif

// Currently used for internal purposes
public protocol TrackDelegate {
    /// Dimensions of the video track has updated
    func track(_ track: VideoTrack, videoView: VideoView, didUpdate dimensions: Dimensions)
    /// Dimensions of the VideoView has updated
    func track(_ track: VideoTrack, videoView: VideoView, didUpdate size: CGSize)
    /// A ``VideoView`` was attached to the ``VideoTrack``
    func track(_ track: VideoTrack, didAttach videoView: VideoView)
    /// A ``VideoView`` was detached from the ``VideoTrack``
    func track(_ track: VideoTrack, didDetach videoView: VideoView)
}

extension TrackDelegate {
    public func track(_ track: VideoTrack, videoView: VideoView, didUpdate dimensions: Dimensions) {}
    public func track(_ track: VideoTrack, videoView: VideoView, didUpdate size: CGSize) {}
    public func track(_ track: VideoTrack, didAttach videoView: VideoView) {}
    public func track(_ track: VideoTrack, didDetach videoView: VideoView) {}
}
