//
//  File.swift
//
//
//  Created by Russell D'Sa on 12/28/20.
//

import CoreMedia
import Foundation

public protocol VideoRenderer {
    func renderFrame(_ frame: VideoFrame)
    func updateVideo(size: CMVideoDimensions, orientation: VideoOrientation)
    func invalidateRenderer()
}
