import CoreMedia
import Foundation

public protocol VideoRenderer {
    func renderFrame(_ frame: VideoFrame)
    func updateVideo(size: Dimensions, orientation: VideoOrientation)
    func invalidateRenderer()
}
