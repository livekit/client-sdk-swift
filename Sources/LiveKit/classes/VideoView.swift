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
    var size: CGSize = .zero
    public private(set) var renderer: RTCVideoRenderer?
    
    required init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        
        #if arch(arm64)
            let view = RTCMTLVideoView(frame: frame)
            view.videoContentMode = .scaleAspectFill
            view.delegate = self
            renderer = view
        #else
            let view = RTCEAGLVideoView(frame: frame)
            view.delegate = self
            renderer = view
        #endif
        
        let rendererView = renderer as! UIView
        rendererView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rendererView)
        
        NSLayoutConstraint.activate([
            rendererView.centerXAnchor.constraint(equalTo: centerXAnchor),
            rendererView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

extension VideoView: RTCVideoViewDelegate {
    public func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        //let orientation = UIDevice.current.orientation
        self.size = size
        
        UIView.animate(withDuration: 0.4) {
            let defaultAspectRatio = CGSize(width: 4, height: 3)
            let aspectRatio = size == .zero ? defaultAspectRatio : size
            let videoFrame = AVMakeRect(aspectRatio: aspectRatio, insideRect: self.bounds)
            
            let rendererView = self.renderer as! UIView
            rendererView.widthAnchor.constraint(equalToConstant: videoFrame.width).isActive = true
            rendererView.heightAnchor.constraint(equalToConstant: videoFrame.height).isActive = true
            
            self.layoutIfNeeded()
        }
    }
}
