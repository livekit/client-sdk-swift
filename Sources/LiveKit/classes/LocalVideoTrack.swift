//
//  File.swift
//
//
//  Created by Russell D'Sa on 12/10/20.
//

import AVFoundation
import CoreMedia
import Foundation
import WebRTC

let simulcastMinWidth = 200

public class LocalVideoTrack: VideoTrack {
    private var capturer: RTCCameraVideoCapturer
    private var source: RTCVideoSource
    public var dimensions: Track.Dimensions

    init(rtcTrack: RTCVideoTrack,
         capturer: RTCCameraVideoCapturer,
         source: RTCVideoSource,
         name: String,
         width: Int,
         height: Int)
    {
        self.capturer = capturer
        self.source = source
        self.dimensions = Dimensions(width: width, height: height)
        super.init(rtcTrack: rtcTrack, name: name)
    }

    private static func createCapturer(options: LocalVideoTrackOptions = LocalVideoTrackOptions()) throws -> (rtcTrack: RTCVideoTrack, capturer: RTCCameraVideoCapturer, source: RTCVideoSource, selectedDimensions: CMVideoDimensions) {

        let source = RTCEngine.factory.videoSource()
        let capturer = RTCCameraVideoCapturer(delegate: source)
        let possibleDevice = RTCCameraVideoCapturer.captureDevices().first { $0.position == options.position }

        guard let device = possibleDevice else {
            throw TrackError.mediaError("No \(options.position) video capture devices available.")
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let (targetWidth, targetHeight) = (options.captureParameter.width, options.captureParameter.height)

        var currentDiff = Int.max
        var selectedFormat: AVCaptureDevice.Format = formats[0]
        var selectedDimension: CMVideoDimensions?
        for format in formats {
            if options.captureFormat == format {
                selectedFormat = format
                break
            }
            let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let diff = abs(targetWidth - Int(dimension.width)) + abs(targetHeight - Int(dimension.height))
            if diff < currentDiff {
                selectedFormat = format
                currentDiff = diff
                selectedDimension = dimension
            }
        }

        guard let selectedDimension = selectedDimension else {
            throw TrackError.mediaError("could not get dimensions")
        }

        let fps = options.captureParameter.maxFrameRate

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

        let rtcTrack = RTCEngine.factory.videoTrack(with: source, trackId: UUID().uuidString)
        rtcTrack.isEnabled = true

        return (rtcTrack, capturer, source, selectedDimension)
    }

    public static func createTrack(name: String, options: LocalVideoTrackOptions = LocalVideoTrackOptions()) throws -> LocalVideoTrack {

        let result = try createCapturer(options: options)
        return LocalVideoTrack(
            rtcTrack: result.rtcTrack,
            capturer: result.capturer,
            source: result.source,
            name: name,
            width: Int(result.selectedDimensions.width),
            height: Int(result.selectedDimensions.height)
        )
    }

    func getVideoEncodings(_ baseEncoding: VideoEncoding?, simulcast: Bool) -> [RTCRtpEncodingParameters] {
        var rtcEncodings: [RTCRtpEncodingParameters] = []
        let baseParams = VideoPreset.getRTPEncodingParams(
            inputWidth: dimensions.width,
            inputHeight: dimensions.height,
            rid: simulcast ? "f" : nil,
            encoding: baseEncoding
        )

        if baseParams != nil {
            rtcEncodings.append(baseParams!)
        }

// not currently supported, fails to encode frame
//        if simulcast {
//            let halfParams = VideoPreset.getRTPEncodingParams(
//                inputWidth: self.width,
//                inputHeight: self.height,
//                rid: "h")
//            if halfParams != nil {
//                rtcEncodings.append(halfParams!)
//            }
//            let quarterParams = VideoPreset.getRTPEncodingParams(
//                inputWidth: self.width,
//                inputHeight: self.height,
//                rid: "q")
//            if quarterParams != nil {
//                rtcEncodings.append(halfParams!)
//            }
//        }

        return rtcEncodings
    }

    public func restartTrack(options: LocalVideoTrackOptions = LocalVideoTrackOptions()) throws {

        let result = try LocalVideoTrack.createCapturer(options: options)

        // Stop previous capturer
        capturer.stopCapture()
        capturer = result.capturer

        source = result.source

        // TODO: Stop previous mediaTrack
        mediaTrack.isEnabled = false
        mediaTrack = result.rtcTrack

        // Set the new track
        sender?.track = result.rtcTrack
    }
}

public struct LocalVideoTrackOptions {
    public var position: AVCaptureDevice.Position = .front
    public var captureFormat: AVCaptureDevice.Format?
    public var captureParameter: VideoCaptureParameter = VideoPreset.qhd.capture

    public init() {}
}

/// resolution and FPS control when capturing video
public struct VideoCaptureParameter {
    public var width: Int
    public var height: Int
    public var maxFrameRate: Float64

    public init(width: Int, height: Int, maxFps: Float64) {
        self.width = width
        self.height = height
        maxFrameRate = maxFps
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
        qvga, vga, qhd, hd, fhd,
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
            if width >= p.capture.width, height >= p.capture.height {
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

        var selectedEncoding: VideoEncoding

        if targetWidth < simulcastMinWidth {
            return nil
        }

        // unless it's original, find the best resolution
        if scaleDownFactor != 1.0 || encoding == nil {
            let preset = getPresetForDimension(width: targetWidth, height: targetHeight)
            targetWidth = preset.capture.width
            scaleDownFactor = Double(inputWidth) / Double(targetWidth)
            targetHeight = Int(Double(inputHeight) / scaleDownFactor)

            selectedEncoding = preset.encoding
        } else {
            selectedEncoding = encoding!
        }

        let params = RTCRtpEncodingParameters()
        params.isActive = true
        params.rid = rid
        params.scaleResolutionDownBy = NSNumber(value: scaleDownFactor)
        params.maxFramerate = NSNumber(value: selectedEncoding.maxFps)
        params.maxBitrateBps = NSNumber(value: selectedEncoding.maxBitrate)
        // only set on the full track
        if scaleDownFactor == 1.0 {
            params.networkPriority = .high
            params.bitratePriority = 4.0
        } else {
            params.networkPriority = .low
            params.bitratePriority = 1.0
        }
        return params
    }
}
