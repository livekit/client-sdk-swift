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

class Utils {

    public static func computeEncodings(
        dimensions: Dimensions?,
        publishOptions: LocalVideoTrackPublishOptions?
    ) -> [RTCRtpEncodingParameters]? {

        let publishOptions = publishOptions ?? LocalVideoTrackPublishOptions()

        var encoding = publishOptions.encoding

        guard let dimensions = dimensions, (publishOptions.simulcast || encoding != nil) else {
            return nil
        }

        let presets = dimensions.computeSuggestedPresets()

        if (encoding == nil) {
            let p = dimensions.computeSuggestedPreset(presets: presets)
            encoding = p.encoding
        }

        guard let encoding = encoding else {
            return nil
        }

        if (!publishOptions.simulcast) {
            // not using simulcast
            return [encoding.toRTCRtpEncoding()]
        }

        // simulcast
        let midPreset = presets[1];
        let lowPreset = presets[0];

        var result: [RTCRtpEncodingParameters] = []

        result.append(encoding.toRTCRtpEncoding(rid: "f"))

        if (dimensions.width >= 960) {
            result.append(contentsOf: [
                midPreset.encoding.toRTCRtpEncoding(
                    rid: "h",
                    scaleDownBy: 2),
                lowPreset.encoding.toRTCRtpEncoding(
                    rid: "q",
                    scaleDownBy: 4)
            ])
        } else {
            result.append(lowPreset.encoding.toRTCRtpEncoding(
                rid: "h",
                scaleDownBy: 2
                )
            )
        }

        return result
    }


    //    func getVideoEncodings(_ baseEncoding: VideoEncoding?, simulcast: Bool) -> [RTCRtpEncodingParameters] {
    //        var rtcEncodings: [RTCRtpEncodingParameters] = []
    ////        let baseParams = VideoPreset.getRTPEncodingParams(
    ////            inputWidth: dimensions.width,
    ////            inputHeight: dimensions.height,
    ////            rid: simulcast ? "f" : nil,
    ////            encoding: baseEncoding
    ////        )
    ////
    ////        if baseParams != nil {
    ////            rtcEncodings.append(baseParams!)
    ////        }
    //
    ////        if simulcast {
    ////            let halfParams = VideoPreset.getRTPEncodingParams(
    ////                inputWidth: dimensions.width,
    ////                inputHeight: dimensions.height,
    ////                rid: "h")
    ////            if halfParams != nil {
    ////                rtcEncodings.append(halfParams!)
    ////            }
    ////            let quarterParams = VideoPreset.getRTPEncodingParams(
    ////                inputWidth: dimensions.width,
    ////                inputHeight: dimensions.height,
    ////                rid: "q")
    ////            if quarterParams != nil {
    ////                rtcEncodings.append(quarterParams!)
    ////            }
    ////        }
    ////        {
    //        let p1 = RTCRtpEncodingParameters()
    //        p1.isActive = true
    //        p1.rid = "f"
    //        p1.scaleResolutionDownBy = NSNumber(value :1)// NSNumber(value: scaleDownFactor)
    //        p1.maxFramerate = NSNumber(value: 15) //NSNumber(value: selectedEncoding.maxFps)
    //        p1.maxBitrateBps = NSNumber(value: 500 * 1024) //NSNumber(value: selectedEncoding.maxBitrate)
    //        rtcEncodings.append(p1)
    //
    //        let p2 = RTCRtpEncodingParameters()
    //        p2.isActive = true
    //        p2.rid = "h"
    //        p2.scaleResolutionDownBy = NSNumber(value :2)// NSNumber(value: scaleDownFactor)
    //        p2.maxFramerate = NSNumber(value: 15) //NSNumber(value: selectedEncoding.maxFps)
    //        p2.maxBitrateBps = NSNumber(value: 500 * 1024) //NSNumber(value: selectedEncoding.maxBitrate)
    //        rtcEncodings.append(p2)
    //
    //
    //        let p3 = RTCRtpEncodingParameters()
    //        p3.isActive = true
    //        p3.rid = "q"
    //        p3.scaleResolutionDownBy = NSNumber(value :4)// NSNumber(value: scaleDownFactor)
    //        p3.maxFramerate = NSNumber(value: 15) //NSNumber(value: selectedEncoding.maxFps)
    //        p3.maxBitrateBps = NSNumber(value: 500 * 1024) //NSNumber(value: selectedEncoding.maxBitrate)
    //        rtcEncodings.append(p3)
    //
    //
    ////        }
    //
    //        return rtcEncodings
    //    }

}

public class LocalVideoTrack: VideoTrack {
    private var capturer: RTCCameraVideoCapturer
    private var source: RTCVideoSource
    public let dimensions: Dimensions

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

    private static func createCapturer(options: LocalVideoTrackOptions = LocalVideoTrackOptions()) throws -> (
        rtcTrack: RTCVideoTrack,
        capturer: RTCCameraVideoCapturer,
        source: RTCVideoSource,
        selectedDimensions: CMVideoDimensions) {

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
    public var captureParameter: VideoCaptureParameter = VideoParameters.presetQHD169.capture

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

extension VideoEncoding {

    func toRTCRtpEncoding(
        rid: String? = nil,
        scaleDownBy: Double = 1
    ) -> RTCRtpEncodingParameters {

        let result = RTCRtpEncodingParameters()
        result.isActive = true

        if let rid = rid {
            result.rid = rid
        }

        // int
        result.numTemporalLayers = NSNumber(value: 1)
        // double
        result.scaleResolutionDownBy = NSNumber(value: scaleDownBy)
        // int
        result.maxFramerate = NSNumber(value: maxFps)
        // int
        result.maxBitrateBps = NSNumber(value: maxBitrate) // 500 * 1024

        // only set on the full track
        if scaleDownBy == 1 {
            result.networkPriority = .high
            result.bitratePriority = 4.0
        } else {
            result.networkPriority = .low
            result.bitratePriority = 1.0
        }

        return result
    }
}

extension Dimensions {

    func computeSuggestedPresets() -> [VideoParameters] {
        let aspect = Double(width) / Double(height)
        if abs(aspect - Dimensions.aspectRatio169) < abs(aspect - Dimensions.aspectRatio43) {
            return VideoParameters.presets169
        }
        return VideoParameters.presets43;
    }

    func computeSuggestedPreset(presets: [VideoParameters]) -> VideoParameters {
        assert(!presets.isEmpty)
        var result = presets[0]
        for p in presets {
            if width >= p.capture.width, height >= p.capture.height {
                result = p
            }
        }
        return result
    }
}

public struct VideoParameters {

    // 4:3 aspect ratio
    public static let presetQVGA43 = VideoParameters(
        capture: VideoCaptureParameter(width: 240, height: 180, maxFps: 15),
        encoding: VideoEncoding(maxBitrate: 100_000, maxFps: 15)
    )
    public static let presetVGA43 = VideoParameters(
        capture: VideoCaptureParameter(width: 480, height: 360, maxFps: 30),
        encoding: VideoEncoding(maxBitrate: 320_000, maxFps: 30)
    )
    public static let presetQHD43 = VideoParameters(
        capture: VideoCaptureParameter(width: 720, height: 540, maxFps: 30),
        encoding: VideoEncoding(maxBitrate: 640_000, maxFps: 30)
    )
    public static let presetHD43 = VideoParameters(
        capture: VideoCaptureParameter(width: 960, height: 720, maxFps: 30),
        encoding: VideoEncoding(maxBitrate: 2_000_000, maxFps: 30)
    )
    public static let presetFHD43 = VideoParameters(
        capture: VideoCaptureParameter(width: 1440, height: 1080, maxFps: 30),
        encoding: VideoEncoding(maxBitrate: 3_200_000, maxFps: 30)
    )

    // 16:9 aspect ratio
    public static let presetQVGA169 = VideoParameters(
        capture: VideoCaptureParameter(width: 320, height: 180, maxFps: 15),
        encoding: VideoEncoding(maxBitrate: 125_000, maxFps: 15)
    )
    public static let presetVGA169 = VideoParameters(
        capture: VideoCaptureParameter(width: 640, height: 360, maxFps: 30),
        encoding: VideoEncoding(maxBitrate: 400_000, maxFps: 30)
    )
    public static let presetQHD169 = VideoParameters(
        capture: VideoCaptureParameter(width: 960, height: 540, maxFps: 30),
        encoding: VideoEncoding(maxBitrate: 800_000, maxFps: 30)
    )
    public static let presetHD169 = VideoParameters(
        capture: VideoCaptureParameter(width: 1280, height: 720, maxFps: 30),
        encoding: VideoEncoding(maxBitrate: 2_500_000, maxFps: 30)
    )
    public static let presetFHD169 = VideoParameters(
        capture: VideoCaptureParameter(width: 1920, height: 1080, maxFps: 30),
        encoding: VideoEncoding(maxBitrate: 4_000_000, maxFps: 30)
    )

    public static let presets43 = [
        presetQVGA43, presetVGA43, presetQHD43, presetHD43, presetFHD43,
    ]

    public static let presets169 = [
        presetQVGA169, presetVGA169, presetQHD169, presetHD169, presetFHD169,
    ]

    public let capture: VideoCaptureParameter
    public let encoding: VideoEncoding

    init(capture: VideoCaptureParameter, encoding: VideoEncoding) {
        self.capture = capture
        self.encoding = encoding
    }

    static func getPresetForDimension(width: Int, height: Int) -> VideoParameters {
        var preset = presets169[0]
        for p in presets169 {
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
