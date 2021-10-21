import CoreMedia
import Foundation

#if !os(macOS)
public protocol VideoViewDelegate {
    func didReceiveData(view: VideoView)
    func dimensionsDidChange(dimensions: CMVideoDimensions, view: VideoView)
    func orientationDidChange(orientation: VideoOrientation, view: VideoView)
}
#endif
