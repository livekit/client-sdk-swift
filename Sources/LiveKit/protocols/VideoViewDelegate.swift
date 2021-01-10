//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/31/20.
//

import Foundation
import CoreMedia

public protocol VideoViewDelegate {
    func didReceiveData(view: VideoView)
    func dimensionsDidChange(dimensions: CMVideoDimensions, view: VideoView)
    func orientationDidChange(orientation: VideoOrientation, view: VideoView)
}
