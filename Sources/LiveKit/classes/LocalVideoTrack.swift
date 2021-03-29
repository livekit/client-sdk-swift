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
    
    public static func createTrack(name: String, options: VideoTrackOptions = VideoTrackOptions()) throws -> LocalVideoTrack {
        let source = RTCEngine.factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: source)
        let possibleDevice = RTCCameraVideoCapturer.captureDevices().first { $0.position == options.position }
        
        guard let device = possibleDevice else {
            throw TrackError.mediaError("No \(options.position) video capture devices available.")
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        var targetWidth: Int, targetHeight: Int
        (targetWidth, targetHeight) = defaultVideoResolutions[0]
        
        var currentDiff = Int.max;
        var selectedFormat: AVCaptureDevice.Format = formats[0]
        for format in formats {
            if options.captureFormat == format {
                selectedFormat = format
                break
            }
            let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            let diff = abs(targetWidth - Int(dimension.width)) + abs(targetHeight - Int(dimension.height));
            if (diff < currentDiff) {
              selectedFormat = format;
              currentDiff = diff;
            }
        }
        
        var fps: Float64 = options.maxFps
        for fpsRange in selectedFormat.videoSupportedFrameRateRanges {
            fps = fmin(fps, fpsRange.maxFrameRate)
        }
        
        logger.info("starting capture with \(device), format: \(selectedFormat), fps: \(fps)")
        capturer.startCapture(with: device, format: selectedFormat, fps: Int(fps))

        let track = RTCEngine.factory.videoTrack(with: source, trackId: UUID().uuidString)
        track.isEnabled = true
        return LocalVideoTrack(rtcTrack: track, capturer: capturer, source: source, name: name)
    }
}

public struct VideoTrackOptions {
    public var position: AVCaptureDevice.Position = .front
    public var maxFps: Float64 = 30
    public var captureFormat: AVCaptureDevice.Format?
    
    public init() {
        
    }
}
