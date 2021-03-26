//
//  File.swift
//  
//
//  Created by Russell D'Sa on 12/10/20.
//

import Foundation
import AVFoundation
import CoreMedia
import WebRTC

public class LocalVideoTrack: VideoTrack {
    private var capturer: RTCCameraVideoCapturer
    private var source: RTCVideoSource
    
    private static var defaultVideoResolutions = [(640, 480), (960, 540), (1280, 720)]
    
    init(rtcTrack: RTCVideoTrack, capturer: RTCCameraVideoCapturer, source: RTCVideoSource, name: String) {
        self.capturer = capturer
        self.source = source
        super.init(rtcTrack: rtcTrack, name: name)
    }
    
    public static func track(enabled: Bool, name: String) throws -> LocalVideoTrack {
        #if TARGET_OS_SIMULATOR
            throw TrackError.mediaError("No video capture devices available.")
        #endif
        
        let source = RTCEngine.factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: source)
        
        let device = RTCCameraVideoCapturer.captureDevices().first { $0.position == .front }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device!)
        var targetWidth: Int, targetHeight: Int
        (targetWidth, targetHeight) = defaultVideoResolutions[0]
        
        var currentDiff = Int.max;
        var selectedFormat: AVCaptureDevice.Format = formats[0]
        for format in formats {
            let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            let diff = abs(targetWidth - Int(dimension.width)) + abs(targetHeight - Int(dimension.height));
            if (diff < currentDiff) {
              selectedFormat = format;
              currentDiff = diff;
            }
        }
        
        var fps: Float64 = 0
        for fpsRange in selectedFormat.videoSupportedFrameRateRanges {
            fps = fmax(fps, fpsRange.maxFrameRate)
        }
        
        if device != nil {
            print("local track --- starting capture with: \(device!)", "format: \(selectedFormat)", "fps: \(fps)")
            capturer.startCapture(with: device!, format: selectedFormat, fps: Int(fps))
        } else {
            throw TrackError.mediaError("Front-facing camera not available on this device.")
        }

        let track = RTCEngine.factory.videoTrack(with: source, trackId: UUID().uuidString)
        track.isEnabled = enabled
        return LocalVideoTrack(rtcTrack: track, capturer: capturer, source: source, name: name)
    }
}
