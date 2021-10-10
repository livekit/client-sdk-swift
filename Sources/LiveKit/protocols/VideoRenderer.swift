import CoreMedia
import Foundation

public protocol VideoRenderer {
    func renderFrame(_ frame: VideoFrame)
    func updateVideo(size: CMVideoDimensions, orientation: VideoOrientation)
    func invalidateRenderer()
}
