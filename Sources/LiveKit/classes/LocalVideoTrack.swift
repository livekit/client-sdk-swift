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

let simulcastMinWidth = 200

public class LocalVideoTrack: VideoTrack {
    private var capturer: RTCCameraVideoCapturer
    private var source: RTCVideoSource
    public let width: Int
    public let height: Int
    
    private static var defaultVideoResolutions = [(640, 480), (960, 540), (1280, 720)]
    
    init(rtcTrack: RTCVideoTrack,
         capturer: RTCCameraVideoCapturer,
         source: RTCVideoSource,
         name: String,
         width: Int,
         height: Int) {
        self.capturer = capturer
        self.source = source
        self.width = width
        self.height = height
        super.init(rtcTrack: rtcTrack, name: name)
    }
    
    public static func createTrack(name: String, options: LocalVideoTrackOptions = LocalVideoTrackOptions()) throws -> LocalVideoTrack {
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
        var selectedDimension: CMVideoDimensions?
        for format in formats {
            if options.captureFormat == format {
                selectedFormat = format
                break
            }
            let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
            let diff = abs(targetWidth - Int(dimension.width)) + abs(targetHeight - Int(dimension.height));
            if (diff < currentDiff) {
                selectedFormat = format
                currentDiff = diff
                selectedDimension = dimension
            }
        }

        guard selectedDimension != nil else {
            throw TrackError.mediaError("could not get dimensions")
        }
        
        var fps = Double(30)
        if let capture = options.captureParameter {
            fps = capture.maxFrameRate
        }
        // discover FPS limits
        var minFps = Double(60)
        var maxFps = Double(0)
        for fpsRange in selectedFormat.videoSupportedFrameRateRanges {
            minFps = min(minFps, fpsRange.minFrameRate)
            maxFps = max(maxFps, fpsRange.maxFrameRate)
        }
        if fps < minFps || fps > maxFps {
            throw TrackError.mediaError("requested framerate is unsupported (\(minFps)-\(maxFps))")
        }
        
        logger.info("starting capture with \(device), format: \(selectedFormat), fps: \(fps)")
        capturer.startCapture(with: device, format: selectedFormat, fps: Int(fps))

        let track = RTCEngine.factory.videoTrack(with: source, trackId: UUID().uuidString)
        track.isEnabled = true
        return LocalVideoTrack(
            rtcTrack: track,
            capturer: capturer,
            source: source,
            name: name,
            width: Int(selectedDimension!.width),
            height: Int(selectedDimension!.height)
        )
    }
    
    func getVideoEncodings(_ baseEncoding: VideoEncoding?, simulcast: Bool) -> [RTCRtpEncodingParameters] {
        var rtcEncodings: [RTCRtpEncodingParameters] = [];
        let baseParams = VideoPreset.getRTPEncodingParams(
            inputWidth: self.width,
            inputHeight: self.height,
            rid: simulcast ? "f" : nil,
            encoding: baseEncoding)
        
        if baseParams != nil {
            rtcEncodings.append(baseParams!)
        }
        
        if simulcast {
            let halfParams = VideoPreset.getRTPEncodingParams(
                inputWidth: self.width,
                inputHeight: self.height,
                rid: "h")
            if halfParams == nil {
                rtcEncodings.append(halfParams!)
            }
            let quarterParams = VideoPreset.getRTPEncodingParams(
                inputWidth: self.width,
                inputHeight: self.height,
                rid: "q")
            if quarterParams == nil {
                rtcEncodings.append(halfParams!)
            }
        }
        
        return rtcEncodings
    }
}

public struct LocalVideoTrackOptions {
    public var position: AVCaptureDevice.Position = .front
    public var captureFormat: AVCaptureDevice.Format?
    public var captureParameter: VideoCaptureParameter?
    
    public init() {
    }
}

/// resolution and FPS control when capturing video
public struct VideoCaptureParameter {
    public var width: Int
    public var height: Int
    public var maxFrameRate: Float64
    
    public init(width: Int, height: Int, maxFps: Float64) {
        self.width = width
        self.height = height
        self.maxFrameRate = maxFps
    }
}

public struct VideoPreset {
    // 4:3 aspect ratio
    
    
    // 16:9 aspect ratio
    public static let qvga = VideoPreset(
        capture: VideoCaptureParameter(width: 320, height: 180, maxFps: 15),
        encoding: VideoEncoding(maxBitrate: 100_000, maxFps: 15)
    )
    public static let vga = VideoPreset(
        capture: VideoCaptureParameter(width: 640, height: 360, maxFps: 30),
        encoding: VideoEncoding(maxBitrate: 400_000, maxFps: 30)
    )
    public static let qhd = VideoPreset(
        capture: VideoCaptureParameter(width: 960, height: 540, maxFps: 30),
        encoding: VideoEncoding(maxBitrate: 700_000, maxFps: 30)
    )
    public static let hd = VideoPreset(
        capture: VideoCaptureParameter(width: 1280, height: 720, maxFps: 30),
        encoding: VideoEncoding(maxBitrate: 2_000_000, maxFps: 30)
    )
    public static let fhd = VideoPreset(
        capture: VideoCaptureParameter(width: 1920, height: 1080, maxFps: 30),
        encoding: VideoEncoding(maxBitrate: 4_000_000, maxFps: 30)
    )
    
    public static let presets = [
        qvga, vga, qhd, hd, fhd
    ]
    
    public let capture: VideoCaptureParameter
    public let encoding: VideoEncoding
    
    init(capture: VideoCaptureParameter, encoding: VideoEncoding) {
        self.capture = capture
        self.encoding = encoding
    }
    
    static func getPresetForDimension(width: Int, height: Int) -> VideoPreset {
        var preset = presets[0]
        for p in presets {
            if width >= p.capture.width && height >= p.capture.height {
                preset = p
            }
        }
        return preset
    }
    
    /// creates encoding parameters that best match input width/height
    static func getRTPEncodingParams(inputWidth: Int, inputHeight: Int, rid: String?, encoding: VideoEncoding? = nil) -> RTCRtpEncodingParameters? {
        var scaleDownFactor = 1.0
        if rid == "h" {
            scaleDownFactor = 2.0
        } else if rid == "q" {
            scaleDownFactor = 4.0
        }
        var targetWidth = Int(Double(inputWidth) / scaleDownFactor)
        var targetHeight = Int(Double(inputHeight) / scaleDownFactor)
        
        var selectedEncoding: VideoEncoding;
        
        // unless it's original, find the best resolution
        if scaleDownFactor != 1.0 || encoding == nil {
            let preset = getPresetForDimension(width: targetWidth, height: targetHeight)
            targetWidth = preset.capture.width
            scaleDownFactor = Double(targetWidth) / Double(inputWidth)
            targetHeight = Int(Double(inputHeight) / scaleDownFactor)
            
            selectedEncoding = preset.encoding
        } else {
            selectedEncoding = encoding!
        }
        
        if targetWidth < simulcastMinWidth {
            return nil
        }
        
        let params = RTCRtpEncodingParameters()
        params.isActive = true
        params.maxBitrateBps = NSNumber(value: selectedEncoding.maxBitrate)
        params.maxFramerate = NSNumber(value: selectedEncoding.maxFps)
        params.rid = rid
        params.scaleResolutionDownBy = NSNumber(value: scaleDownFactor)
        return params
    }
}
