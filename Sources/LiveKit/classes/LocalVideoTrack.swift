//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/10/20.
//

import Foundation
import AVFoundation
import WebRTC

public class LocalVideoTrack: VideoTrack {
    private var capturer: RTCVideoCapturer
    override public var enabled: Bool {
        get { rtcTrack.isEnabled }
        set { rtcTrack.isEnabled = newValue }
    }
    
    init(rtcTrack: RTCVideoTrack, capturer: RTCVideoCapturer, name: String) {
        self.capturer = capturer
        super.init(rtcTrack: rtcTrack, name: name)
    }
    
    public static func track(source: AVCaptureDevice, enabled: Bool, name: String) -> LocalVideoTrack {
        let source = RTCEngine.factory.videoSource()
        var capturer: RTCVideoCapturer
        #if TARGET_OS_SIMULATOR
            capturer = RTCFileVideoCapturer(delegate: source)
        #else
            capturer = RTCCameraVideoCapturer(delegate: source)
        #endif
        
        let track = RTCEngine.factory.videoTrack(with: source, trackId: UUID().uuidString)
        track.isEnabled = enabled
        return LocalVideoTrack(rtcTrack: track, capturer: capturer, name: name)
    }
}
