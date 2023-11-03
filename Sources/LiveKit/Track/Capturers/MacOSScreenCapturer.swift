/*
 * Copyright 2022 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import AVFoundation

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

@_implementationOnly import WebRTC

#if os(macOS)

@available(macOS 12.3, *)
public class MacOSScreenCapturer: VideoCapturer {

    private let capturer = Engine.createVideoCapturer()

    // TODO: Make it possible to change dynamically
    public let captureSource: MacOSScreenCaptureSource?

    // SCStream
    private var _scStream: SCStream?

    // cached frame for resending to maintain minimum of 1 fps
    private var _lastFrame: LKRTCVideoFrame?
    private var _resendTimer: Task<Void, Error>?

    /// The ``ScreenShareCaptureOptions`` used for this capturer.
    /// It is possible to modify the options but `restartCapture` must be called.
    public var options: ScreenShareCaptureOptions

    init(delegate: LKRTCVideoCapturerDelegate, captureSource: MacOSScreenCaptureSource, options: ScreenShareCaptureOptions) {
        self.captureSource = captureSource
        self.options = options
        super.init(delegate: delegate)
    }

    public override func startCapture() async throws -> Bool {

        let didStart = try await super.startCapture()

        // Already started
        guard didStart else { return false }

        guard let captureSource = self.captureSource else {
            throw TrackError.capturer(message: "captureSource is nil")
        }

        let filter: SCContentFilter
        if let windowSource = captureSource as? MacOSWindow,
           let nativeWindowSource = windowSource.nativeType as? SCWindow {
            filter = SCContentFilter(desktopIndependentWindow: nativeWindowSource)
        } else if let displaySource = captureSource as? MacOSDisplay,
                  let content = displaySource.scContent as? SCShareableContent,
                  let nativeDisplay = displaySource.nativeType as? SCDisplay {
            let excludedApps = content.applications.filter { app in
                Bundle.main.bundleIdentifier == app.bundleIdentifier
            }
            filter = SCContentFilter(display: nativeDisplay, excludingApplications: excludedApps, exceptingWindows: [])
        } else {
            throw TrackError.capturer(message: "Unable to resolve SCContentFilter")
        }

        let configuration = SCStreamConfiguration()

        let mainDisplay = CGMainDisplayID()
        // try to capture in max resolution
        configuration.width = CGDisplayPixelsWide(mainDisplay) * 2
        configuration.height = CGDisplayPixelsHigh(mainDisplay) * 2

        configuration.scalesToFit = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.options.fps))
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = self.options.showCursor

        // Why does SCStream hold strong reference to delegate?
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
        try await stream.startCapture()

        self._scStream = stream

        return true
    }

    public override func stopCapture() async throws -> Bool {

        let didStop = try await super.stopCapture()

        // Already stopped
        guard didStop else { return false }

        guard let stream = _scStream else {
            throw TrackError.capturer(message: "SCStream is nil")
        }

        // Stop resending paused frames
        _resendTimer?.cancel()
        _resendTimer = nil

        try await stream.stopCapture()
        try stream.removeStreamOutput(self, type: .screen)
        _scStream = nil

        return true
    }

    // common capture func
    private func capture(_ sampleBuffer: CMSampleBuffer, cropRect: CGRect? = nil) {

        guard let delegate = delegate else { return }

        // Get the pixel buffer that contains the image data.
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(timeStamp) * Double(NSEC_PER_SEC))

        let sourceDimensions: Dimensions
        if let cropRect = cropRect {
            // use dimensions from provided rect
            sourceDimensions = Dimensions(width: Int32((cropRect.width * 2).rounded(.down)),
                                          height: Int32((cropRect.height * 2).rounded(.down)))
        } else {
            // use pixel buffer dimensions
            sourceDimensions = Dimensions(width: Int32(CVPixelBufferGetWidth(pixelBuffer)),
                                          height: Int32(CVPixelBufferGetHeight(pixelBuffer)))
        }

        let targetDimensions = sourceDimensions
            .aspectFit(size: self.options.dimensions.max)
            .toEncodeSafeDimensions()

        // notify capturer for dimensions
        defer { self.dimensions = targetDimensions }

        let rtcBuffer = LKRTCCVPixelBuffer(pixelBuffer: pixelBuffer,
                                           adaptedWidth: targetDimensions.width,
                                           adaptedHeight: targetDimensions.height,
                                           cropWidth: sourceDimensions.width,
                                           cropHeight: sourceDimensions.height,
                                           cropX: Int32(cropRect?.origin.x ?? 0),
                                           cropY: Int32(cropRect?.origin.y ?? 0))

        let rtcFrame = LKRTCVideoFrame(buffer: rtcBuffer,
                                       rotation: ._0,
                                       timeStampNs: timeStampNs)

        // feed frame to WebRTC
        delegate.capturer(capturer, didCapture: rtcFrame)

        // cache last frame
        _lastFrame = rtcFrame
    }
}

// MARK: - Frame resend logic

@available(macOS 12.3, *)
extension MacOSScreenCapturer {

    private func _capturePreviousFrame() async throws {

        // Must be .started
        guard case .started = captureState else {
            log("CaptureState is not .started, resend timer should not trigger.", .warning)
            return
        }

        log("No movement detected, resending frame...")

        guard let delegate = delegate, let frame = _lastFrame else { return }

        // create a new frame with new time stamp
        let newFrame = LKRTCVideoFrame(buffer: frame.buffer,
                                       rotation: frame.rotation,
                                       timeStampNs: Self.createTimeStampNs())

        // feed frame to WebRTC
        delegate.capturer(capturer, didCapture: newFrame)
    }
}

// MARK: - SCStreamOutput

@available(macOS 12.3, *)
extension MacOSScreenCapturer: SCStreamOutput {

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {

        guard case .started = captureState else {
            log("Skipping capture since captureState is not .started")
            return
        }

        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                             createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first else { return }

        // Validate the status of the frame. If it isn't `.complete`, return nil.
        guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue) else {
            return
        }

        /// @constant SCFrameStatusComplete new frame was generated.
        /// @constant SCFrameStatusIdle new frame was not generated because the display did not change.
        /// @constant SCFrameStatusBlank new frame was not generated because the display has gone blank.
        /// @constant SCFrameStatusSuspended new frame was not generated because updates haves been suspended
        /// @constant SCFrameStatusStarted new frame that is indicated as the first frame sent after the stream has started.
        /// @constant SCFrameStatusStopped the stream was stopped.
        guard status == .complete else {
            return
        }

        // Get the pixel buffer that contains the image data.
        // guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        // Get the backing IOSurface.
        // guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        // let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)

        // Retrieve the content rectangle, scale, and scale factor.

        // let contentScale = attachments[.contentScale] as? CGFloat,
        // let scaleFactor = attachments[.scaleFactor] as? CGFloat

        guard let dict = attachments[.contentRect] as? NSDictionary,
              let contentRect = CGRect(dictionaryRepresentation: dict) else {
            return
        }

        capture(sampleBuffer, cropRect: contentRect)

        _resendTimer?.cancel()
        _resendTimer = Task.detached(priority: .utility) { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(1 * 1_000_000_000))
                if Task.isCancelled { break }
                guard let self else { break }
                try await self._capturePreviousFrame()
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

@available(macOS 12.3, *)
extension LocalVideoTrack {

    @objc
    public static func createMacOSScreenShareTrack(name: String = Track.screenShareVideoName,
                                                   source: MacOSScreenCaptureSource,
                                                   options: ScreenShareCaptureOptions = ScreenShareCaptureOptions()) -> LocalVideoTrack {

        let videoSource = Engine.createVideoSource(forScreenShare: true)
        let capturer = MacOSScreenCapturer(delegate: videoSource, captureSource: source, options: options)
        return LocalVideoTrack(
            name: name,
            source: .screenShareVideo,
            capturer: capturer,
            videoSource: videoSource
        )
    }
}

@objc
public enum MacOSScreenShareSourceType: Int {
    case any
    case display
    case window
}

@objc
public protocol MacOSScreenCaptureSource: AnyObject {

}

@objc
public class MacOSRunningApplication: NSObject {

    public let processID: pid_t
    public let bundleIdentifier: String
    public let applicationName: String

    public let nativeType: Any?

    @available(macOS 12.3, *)
    internal init?(from scRunningApplication: SCRunningApplication?) {
        guard let scRunningApplication = scRunningApplication else { return nil }
        self.bundleIdentifier = scRunningApplication.bundleIdentifier
        self.applicationName = scRunningApplication.applicationName
        self.processID = scRunningApplication.processID
        self.nativeType = scRunningApplication
    }

    internal init?(from processID: pid_t?) {

        guard let processID = processID,
              let app = NSRunningApplication(processIdentifier: processID) else { return nil }

        self.processID = processID
        self.bundleIdentifier = app.bundleIdentifier ?? ""
        self.applicationName = app.localizedName ?? ""
        self.nativeType = nil
    }
}

@objc
public class MacOSWindow: NSObject, MacOSScreenCaptureSource {

    public let windowID: CGWindowID
    public let frame: CGRect
    public let title: String?
    public let windowLayer: Int
    public let owningApplication: MacOSRunningApplication?
    public let isOnScreen: Bool
    public let nativeType: Any?

    @available(macOS 12.3, *)
    internal init(from scWindow: SCWindow) {
        self.windowID = scWindow.windowID
        self.frame = scWindow.frame
        self.title = scWindow.title
        self.windowLayer = scWindow.windowLayer
        self.owningApplication = MacOSRunningApplication(from: scWindow.owningApplication)
        self.isOnScreen = scWindow.isOnScreen
        self.nativeType = scWindow
    }

    internal init(from windowID: CGWindowID) {
        self.windowID = windowID

        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)! as Array

        guard let info = list.first as? NSDictionary else {
            fatalError("Window information not available")
        }

        self.frame = {

            guard let dict = info.object(forKey: kCGWindowBounds) as? NSDictionary,
                  let frame = CGRect.init(dictionaryRepresentation: dict) else {
                //
                return CGRect()
            }

            return frame
        }()

        self.title = info.object(forKey: kCGWindowName) as? String
        self.windowLayer = (info.object(forKey: kCGWindowLayer) as? NSNumber)?.intValue ?? 0
        self.owningApplication = MacOSRunningApplication(from: (info.object(forKey: kCGWindowOwnerPID) as? NSNumber)?.int32Value as? pid_t)
        self.isOnScreen = (info.object(forKey: kCGWindowIsOnscreen) as? NSNumber)?.boolValue ?? false
        self.nativeType = nil
    }
}

@objc
public class MacOSDisplay: NSObject, MacOSScreenCaptureSource {

    public let displayID: CGDirectDisplayID
    public let width: Int
    public let height: Int
    public let frame: CGRect

    public let nativeType: Any?
    public let scContent: Any?

    @available(macOS 12.3, *)
    internal init(from scDisplay: SCDisplay, content: SCShareableContent) {
        self.displayID = scDisplay.displayID
        self.width = scDisplay.width
        self.height = scDisplay.height
        self.frame = scDisplay.frame
        self.nativeType = scDisplay
        self.scContent = content
    }

    // legacy
    internal init(from displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.width = CGDisplayPixelsWide(displayID)
        self.height = CGDisplayPixelsHigh(displayID)
        self.frame = CGRect(x: 0,
                            y: 0,
                            width: width,
                            height: height)
        self.nativeType = nil
        self.scContent = nil
    }
}

// MARK: - Filter extension

extension MacOSWindow {

    /// Source is related to current running application
    @objc
    public var isCurrentApplication: Bool {
        owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}

// MARK: - Enumerate sources

@available(macOS 12.3, *)
extension MacOSScreenCapturer {

    internal static let queue = DispatchQueue(label: "LiveKitSDK.MacOSScreenCapturer.sources", qos: .default)

    /// Convenience method to get a ``MacOSDisplay`` of the main display.
    @objc
    public static func mainDisplaySource() async throws -> MacOSDisplay {

        let displaySources = try await sources(for: .display)

        guard let source = displaySources.compactMap({ $0 as? MacOSDisplay }).first(where: { $0.displayID == CGMainDisplayID() }) else {
            throw TrackError.capturer(message: "Main display source not found")
        }

        return source
    }

    /// Enumerate ``MacOSDisplay`` or ``MacOSWindow`` sources.
    @objc
    public static func sources(for type: MacOSScreenShareSourceType, includeCurrentApplication: Bool = false) async throws -> [MacOSScreenCaptureSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = content.displays.map { MacOSDisplay(from: $0, content: content) }
        let windows = content.windows
            // remove windows from this app
            .filter { includeCurrentApplication || $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
            // remove windows that don't have an associated bundleIdentifier
            .filter { $0.owningApplication?.bundleIdentifier != nil }
            // remove windows that windowLayer isn't 0
            .filter { $0.windowLayer == 0 }
            // remove windows that are unusually small
            .filter { $0.frame.size.width >= 100 && $0.frame.size.height >= 100 }
            // sort the windows by app name
            .sorted { $0.owningApplication?.applicationName ?? "" < $1.owningApplication?.applicationName ?? "" }
            .map { MacOSWindow(from: $0) }

        switch type {
        case .any: return displays + windows
        case .display: return displays
        case .window: return windows
        }
    }

    @objc
    public static func displaySources() async throws -> [MacOSDisplay] {
        let result = try await sources(for: .display)
        // Cast
        return result.compactMap({ $0 as? MacOSDisplay })
    }

    @objc
    public static func windowSources() async throws -> [MacOSWindow] {
        let result = try await sources(for: .window)
        // Cast
        return result.compactMap({ $0 as? MacOSWindow })
    }
}

#endif
