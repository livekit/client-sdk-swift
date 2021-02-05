//
//  CameraSourceOptions.swift
//  
//
//  Created by Russell D'Sa on 1/31/21.
//

import Foundation

public typealias CameraSourceOptionsBuilderBlock = (inout CameraSourceOptions) -> Void

public struct CameraSourceOptions {
    
    public var enablePreview: Bool = false
    public var rotationTags: CameraSourceOptionsRotationTags = .keep
    public var zoomFactor: Float = 1.0
    
    fileprivate init() {}
    
    public static func options(block: CameraSourceOptionsBuilderBlock) -> CameraSourceOptions {
        var options = CameraSourceOptions()
        block(&options)
        return options
    }
}
