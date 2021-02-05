//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/31/20.
//

import Foundation
import UIKit
import CoreMedia
import WebRTC

public class VideoView: UIView {
//    public var delegate: VideoViewDelegate?
//    public var viewShouldRotateContent: Bool = true
//    public private(set) var dimensions: CMVideoDimensions?
//    public private(set) var orientation: VideoOrientation?
//    public private(set) var hasVideoData: Bool = false
//    public private(set) var mirror: Bool = false
//    
    public private(set) var renderer: RTCVideoRenderer?
    
    required init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
    }
    
    public init(frame: CGRect, delegate: VideoViewDelegate? = nil, renderingType: VideoRenderingType? = .none) {
        super.init(frame: frame)
        #if arch(arm64)
            // Using metal (arm64 only)
            switch renderingType {
            case .metal:
                let view = RTCMTLVideoView(frame: frame)
                view.videoContentMode = .scaleAspectFill
                renderer = view
            case .opengles:
                renderer = RTCEAGLVideoView(frame: frame)
            default:
                break
            }
        #else
            renderer = RTCEAGLVideoView(frame: frame)
        #endif
        
        addSubview(renderer as! UIView)
    }
}

extension VideoView: RTCVideoRenderer {
    public func setSize(_ size: CGSize) {
        print("video view --- set size called with size: \(size)")
    }
    
    public func renderFrame(_ frame: RTCVideoFrame?) {
        print("video view --- received video frame")
    }
    
//    public func renderFrame(_ frame: VideoFrame) {
//
//    }
//
//    public func updateVideo(size: CMVideoDimensions, orientation: VideoOrientation) {
//
//    }
//
//    public func invalidateRenderer() {
//
//    }
}
