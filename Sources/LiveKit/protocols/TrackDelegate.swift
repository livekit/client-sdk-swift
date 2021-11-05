import Foundation

#if !os(macOS)
import UIKit
#endif

// Currenlty used for internal purposes
public protocol TrackDelegate {
    /// Dimensions of the video track has changed
    func track(_ track: VideoTrack, videoView: VideoView, didUpdate dimensions: Dimensions)
    /// Dimensions of the VideoView has changed
    func track(_ track: VideoTrack, videoView: VideoView, didUpdate size: CGSize)
    func track(_ track: VideoTrack, didAttach videoView: VideoView)
    func track(_ track: VideoTrack, didDetach videoView: VideoView)
}

extension TrackDelegate {
    public func track(_ track: VideoTrack, videoView: VideoView, didUpdate dimensions: Dimensions) {}
    public func track(_ track: VideoTrack, videoView: VideoView, didUpdate size: CGSize) {}
    public func track(_ track: VideoTrack, didAttach videoView: VideoView) {}
    public func track(_ track: VideoTrack, didDetach videoView: VideoView) {}
}
