import CoreMedia
import Foundation

#if os(iOS)
public protocol VideoViewDelegate {
    func didReceiveData(view: VideoView)
    func dimensionsDidChange(dimensions: Dimensions, view: VideoView)
    func orientationDidChange(orientation: VideoOrientation, view: VideoView)
}
#endif
