//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/28/20.
//

import Foundation
import CoreMedia

public protocol VideoRenderer {
    func renderFrame(_ frame: VideoFrame)
    func updateVideo(size: CMVideoDimensions, orientation: VideoOrientation)
    func invalidateRenderer()
}
