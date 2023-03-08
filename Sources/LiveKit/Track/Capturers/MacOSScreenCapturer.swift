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
import WebRTC
import Promises

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

// currently only used for macOS
@available(*, deprecated, message: "Use new API with MacOSScreenShareSource")
public enum ScreenShareSource {
    case display(id: UInt32)
    case window(id: UInt32)
}

#if os(macOS)

@available(*, deprecated, message: "Use new API with MacOSScreenShareSource")
extension ScreenShareSource {
    public static let mainDisplay: ScreenShareSource = .display(id: CGMainDisplayID())
}

@objc
public enum MacOSScreenCapturePreferredMethod: Int {
    case auto
    case screenCaptureKit
    case legacy
}

@objc
public enum MacOSScreenCaptureMethod: Int {
    case screenCaptureKit
    case legacy
}

extension MacOSScreenCapturer {

    internal static func computeCaptureMethod(preferredMethod: MacOSScreenCapturePreferredMethod) -> MacOSScreenCaptureMethod {

        if case .legacy = preferredMethod {
            return .legacy
        }

        if #available(macOS 12.3, *) {
            return .screenCaptureKit
        }

        return .legacy
    }
}

public class MacOSScreenCapturer: VideoCapturer {

    private let captureQueue = DispatchQueue(label: "LiveKitSDK.macOSScreenCapturer", qos: .default)
    private let capturer = Engine.createVideoCapturer()

    // TODO: Make it possible to change dynamically
    public let captureSource: MacOSScreenCaptureSource?

    // SCStream
    private var _scStream: Any?

    // cached frame for resending to maintain minimum of 1 fps
    private var lastFrame: RTCVideoFrame?
    private var frameResendTimer: DispatchQueueTimer?
    private let captureMethod: MacOSScreenCaptureMethod

    // MARK: - Legacy support (Deprecated)

    // used for display capture
    private lazy var session: AVCaptureSession = {

        assert(.legacy == captureMethod, "Should be only executed for legacy mode")

        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: captureQueue)
        return session
    }()

    // used to generate frames for window capture
    private var dispatchSourceTimer: DispatchQueueTimer?

    private func startDispatchSourceTimer() {

        // must be called on captureQueue
        dispatchPrecondition(condition: .onQueue(captureQueue))

        assert(.legacy == captureMethod, "Should be only executed for legacy mode")

        stopDispatchSourceTimer()

        let timeInterval: TimeInterval = 1 / Double(options.fps)
        dispatchSourceTimer = DispatchQueueTimer(timeInterval: timeInterval, queue: captureQueue)
        dispatchSourceTimer?.handler = { [weak self] in self?.onDispatchSourceTimer() }
        dispatchSourceTimer?.resume()
    }

    private func stopDispatchSourceTimer() {

        // must be called on captureQueue
        dispatchPrecondition(condition: .onQueue(captureQueue))

        assert(.legacy == captureMethod, "Should be only executed for legacy mode")

        log()

        if let timer = dispatchSourceTimer {
            timer.suspend()
        }

        dispatchSourceTimer = nil
    }

    /// The ``ScreenShareCaptureOptions`` used for this capturer.
    /// It is possible to modify the options but `restartCapture` must be called.
    public var options: ScreenShareCaptureOptions

    @available(*, deprecated, message: "Use new API with MacOSScreenShareSource")
    init(delegate: RTCVideoCapturerDelegate,
         source: ScreenShareSource,
         options: ScreenShareCaptureOptions,
         preferredMethod: MacOSScreenCapturePreferredMethod = .auto) {

        // compatibility
        self.captureSource = source.toScreenCaptureSource()
        self.options = options
        self.captureMethod = Self.computeCaptureMethod(preferredMethod: preferredMethod)
        super.init(delegate: delegate)
    }

    init(delegate: RTCVideoCapturerDelegate,
         captureSource: MacOSScreenCaptureSource,
         options: ScreenShareCaptureOptions,
         preferredMethod: MacOSScreenCapturePreferredMethod = .auto) {

        self.captureSource = captureSource
        self.options = options
        self.captureMethod = Self.computeCaptureMethod(preferredMethod: preferredMethod)
        super.init(delegate: delegate)
    }

    deinit {
        log()
        assert(dispatchSourceTimer == nil, "dispatchSourceTimer is not nil")
        assert(frameResendTimer == nil, "frameResendTimer is not nil")
    }

    private func onDispatchSourceTimer() {

        // must be called on captureQueue
        dispatchPrecondition(condition: .onQueue(captureQueue))

        assert(.legacy == captureMethod, "Should be only executed for legacy mode")

        guard case .started = self.captureState,
              let windowSource = captureSource as? MacOSWindow else { return }

        guard let image = CGWindowListCreateImage(CGRect.null,
                                                  .optionIncludingWindow,
                                                  windowSource.windowID, [.shouldBeOpaque,
                                                                          .bestResolution,
                                                                          .boundsIgnoreFraming]),
              let pixelBuffer = image.toPixelBuffer(pixelFormatType: kCVPixelFormatType_32ARGB) else { return }

        // TODO: Convert kCVPixelFormatType_32ARGB to kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // h264 encoder may cause issues with ARGB format
        // vImageConvert_ARGB8888To420Yp8_CbCr8()

        self.delegate?.capturer(self.capturer,
                                didCapture: pixelBuffer,
                                onResolveSourceDimensions: { sourceDimensions in

                                    let targetDimensions = sourceDimensions
                                        .aspectFit(size: self.options.dimensions.max)
                                        .toEncodeSafeDimensions()

                                    defer { self.dimensions = targetDimensions }

                                    guard let videoSource = self.delegate as? RTCVideoSource else { return }
                                    // self.log("adaptOutputFormat to: \(targetDimensions) fps: \(self.options.fps)")
                                    videoSource.adaptOutputFormat(toWidth: targetDimensions.width,
                                                                  height: targetDimensions.height,
                                                                  fps: Int32(self.options.fps))
                                })

    }

    public override func startCapture() -> Promise<Bool> {

        func createStartPromise(_ didStart: Bool) -> Promise<Bool> {

            guard didStart else {
                // already started
                return Promise(false)
            }

            return Promise<Bool>(on: self.queue) { fulfill, reject in

                if #available(macOS 12.3, *), case .screenCaptureKit = self.captureMethod {

                    guard let captureSource = self.captureSource else {
                        fulfill(false)
                        return
                    }

                    Task {
                        do {
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
                                reject(TrackError.capturer(message: "Unable to resolve SCContentFilter"))
                                return
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
                            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)
                            try await stream.startCapture()

                            self._scStream = stream

                            fulfill(true)

                        } catch let error {
                            self.log("capture: error: \(error)", .error)
                            reject(error)
                        }
                    }

                } else {

                    if let displaySource = self.captureSource as? MacOSDisplay {

                        // legacy support

                        // clear all previous inputs
                        for input in self.session.inputs {
                            self.session.removeInput(input)
                        }

                        // try to create a display input
                        guard let input = AVCaptureScreenInput(displayID: displaySource.displayID) else {
                            // fail promise if displayID is invalid
                            throw TrackError.capturer(message: "Failed to create screen input with source: \(displaySource)")
                        }

                        input.minFrameDuration = CMTimeMake(value: 1, timescale: Int32(self.options.fps))
                        input.capturesCursor = true
                        input.capturesMouseClicks = true
                        self.session.addInput(input)

                        self.session.startRunning()

                        fulfill(true)

                    } else if self.captureSource is MacOSWindow {

                        self.captureQueue.async {
                            // window capture mode
                            self.startDispatchSourceTimer()

                            self.queue.async {
                                fulfill(true)
                            }
                        }
                    }
                }
            }
        }

        return super.startCapture().then(on: queue) { didStart -> Promise<Bool> in
            createStartPromise(didStart)
        }
    }

    public override func stopCapture() -> Promise<Bool> {

        func createStopPromise(_ didStop: Bool) -> Promise<Bool> {

            guard didStop else {
                // already stopped
                return Promise(false)
            }

            return Promise<Bool>(on: self.queue) { fulfill, reject in

                if #available(macOS 12.3, *), case .screenCaptureKit = self.captureMethod {

                    guard let stream = self._scStream as? SCStream else {
                        assert(false, "SCStream is nil")
                        fulfill(true)
                        return
                    }

                    self.captureQueue.async {
                        // stop resending paused frames
                        self.stopFrameResendTimer()

                        self.queue.async {
                            //
                            Task {
                                do {
                                    try await stream.stopCapture()
                                    try stream.removeStreamOutput(self, type: .screen)
                                    self._scStream = nil
                                    fulfill(true)
                                } catch let error {
                                    reject(error)
                                }
                            }
                        }
                    }

                } else {

                    // legacy support

                    if self.captureSource is MacOSDisplay {
                        self.session.stopRunning()
                        fulfill(true)
                    } else if self.captureSource is MacOSWindow {
                        self.captureQueue.async {
                            self.stopDispatchSourceTimer()
                            self.queue.async {
                                fulfill(true)
                            }
                        }
                    }
                }
            }
        }

        return super.stopCapture().then(on: queue) { didStop -> Promise<Bool> in
            createStopPromise(didStop)
        }
    }

    // common capture func
    private func capture(_ sampleBuffer: CMSampleBuffer, cropRect: CGRect? = nil) {

        // must be called on captureQueue
        dispatchPrecondition(condition: .onQueue(captureQueue))

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

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer,
                                         adaptedWidth: targetDimensions.width,
                                         adaptedHeight: targetDimensions.height,
                                         cropWidth: sourceDimensions.width,
                                         cropHeight: sourceDimensions.height,
                                         cropX: Int32(cropRect?.origin.x ?? 0),
                                         cropY: Int32(cropRect?.origin.y ?? 0))

        let rtcFrame = RTCVideoFrame(buffer: rtcBuffer,
                                     rotation: ._0,
                                     timeStampNs: timeStampNs)

        // feed frame to WebRTC
        delegate.capturer(capturer, didCapture: rtcFrame)

        // cache last frame
        lastFrame = rtcFrame
    }
}

// MARK: - Frame resend logic

extension MacOSScreenCapturer {

    private func restartFrameResendTimer() {

        dispatchPrecondition(condition: .onQueue(captureQueue))

        assert(.screenCaptureKit == captureMethod, "Should be only executed for .screenCaptureKit mode")

        stopFrameResendTimer()

        let timeInterval: TimeInterval = 1 / Double(1 /* 1 fps */)

        frameResendTimer = {
            let timer = DispatchQueueTimer(timeInterval: timeInterval, queue: self.captureQueue)
            timer.handler = { [weak self] in self?.onFrameResendTimer() }
            timer.resume()
            return timer
        }()
    }

    private func stopFrameResendTimer() {

        dispatchPrecondition(condition: .onQueue(captureQueue))

        assert(.screenCaptureKit == captureMethod, "Should be only executed for .screenCaptureKit mode")

        if let timer = frameResendTimer {
            timer.suspend()
        }

        frameResendTimer = nil
    }

    private func onFrameResendTimer() {

        // must be called on captureQueue
        dispatchPrecondition(condition: .onQueue(captureQueue))

        // must be .started
        guard case .started = captureState else {
            log("captureState is not .started, resend timer should not trigger.", .warning)
            return
        }

        log("no movement detected, resending frame...")

        guard let delegate = delegate,
              let frame = lastFrame else { return }

        // create a new frame with new time stamp
        let newFrame = RTCVideoFrame(buffer: frame.buffer,
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

        restartFrameResendTimer()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension MacOSScreenCapturer: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {

        assert(.legacy == captureMethod, "Should be only executed for legacy mode")

        guard case .started = captureState else {
            log("Skipping capture since captureState is not .started")
            return
        }

        capture(sampleBuffer)
    }
}

extension LocalVideoTrack {

    /// Creates a track that captures the whole desktop screen
    @available(*, deprecated, message: "Use new API with MacOSScreenShareSource")
    public static func createMacOSScreenShareTrack(name: String = Track.screenShareVideoName,
                                                   source: ScreenShareSource = .mainDisplay,
                                                   options: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                                                   preferredMethod: MacOSScreenCapturePreferredMethod = .auto) -> LocalVideoTrack {

        let videoSource = Engine.createVideoSource(forScreenShare: true)
        let capturer = MacOSScreenCapturer(delegate: videoSource, source: source, options: options, preferredMethod: preferredMethod)
        return LocalVideoTrack(
            name: name,
            source: .screenShareVideo,
            capturer: capturer,
            videoSource: videoSource
        )
    }

    @objc
    public static func createMacOSScreenShareTrack(name: String = Track.screenShareVideoName,
                                                   source: MacOSScreenCaptureSource,
                                                   options: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                                                   preferredMethod: MacOSScreenCapturePreferredMethod = .auto) -> LocalVideoTrack {

        let videoSource = Engine.createVideoSource(forScreenShare: true)
        let capturer = MacOSScreenCapturer(delegate: videoSource, captureSource: source, options: options, preferredMethod: preferredMethod)
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

@available(*, deprecated, message: "Use MacOSScreenCaptureSource instead")
extension ScreenShareSource {

    func toScreenCaptureSource() -> MacOSScreenCaptureSource {
        switch self {
        case .window(let id): return MacOSWindow(from: id)
        case .display(let id): return MacOSDisplay(from: id)
        }
    }
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

extension MacOSScreenCapturer {

    internal static let queue = DispatchQueue(label: "LiveKitSDK.MacOSScreenCapturer.sources", qos: .default)

    /// Convenience method to get a ``MacOSDisplay`` of the main display.
    public static func mainDisplaySource() -> Promise<MacOSDisplay> {
        sources(for: .display).then(on: queue) { sources in

            guard let source = sources.compactMap({ $0 as? MacOSDisplay }).first(where: { $0.displayID == CGMainDisplayID() }) else {
                throw TrackError.capturer(message: "Main display source not found")
            }

            return source
        }
    }

    /// Enumerate ``MacOSDisplay`` or ``MacOSWindow`` sources.
    public static func sources(for type: MacOSScreenShareSourceType,
                               includeCurrentApplication: Bool = false,
                               preferredMethod: MacOSScreenCapturePreferredMethod = .auto) -> Promise<[MacOSScreenCaptureSource]> {

        return Promise<[MacOSScreenCaptureSource]> { fulfill, reject in

            if #available(macOS 12.3, *), case .screenCaptureKit = Self.computeCaptureMethod(preferredMethod: preferredMethod) {

                Task {
                    do {
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        let displays = content.displays.map { MacOSDisplay(from: $0, content: content) }
                        let windows = content.windows
                            // remove windows from this app
                            .filter { includeCurrentApplication || $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
                            // remove windows that don't have an associated bundleIdentifier
                            .filter { $0.owningApplication?.bundleIdentifier != nil }
                            // remove windows that windowLayer isn't 0
                            .filter { $0.windowLayer == 0 }
                            // sort the windows by app name
                            .sorted { $0.owningApplication?.applicationName ?? "" < $1.owningApplication?.applicationName ?? "" }
                            .map { MacOSWindow(from: $0) }

                        switch type {
                        case .any:
                            fulfill(displays + windows)
                        case .display:
                            fulfill(displays)
                        case .window:
                            fulfill(windows)
                        }

                    } catch let error {
                        reject(error)
                    }
                }
            } else {
                // TODO: fallback for earlier versions

                let displays = _displayIDs().map { MacOSDisplay(from: $0) }
                let windows = _windowIDs(includeCurrentProcess: includeCurrentApplication).map { MacOSWindow(from: $0) }

                switch type {
                case .any:
                    fulfill(displays + windows)
                case .display:
                    fulfill(displays)
                case .window:
                    fulfill(windows)
                }
            }
        }
    }

    public static func displaySources() -> Promise<[MacOSDisplay]> {
        sources(for: .display).then(on: queue) { sources in
            // cast
            sources.compactMap({ $0 as? MacOSDisplay })
        }
    }

    public static func windowSources() -> Promise<[MacOSWindow]> {
        sources(for: .window).then(on: queue) { sources in
            // cast
            sources.compactMap({ $0 as? MacOSWindow })
        }
    }
}

// MARK: - Enumerate sources (Deprecated)

extension MacOSScreenCapturer {

    @available(*, deprecated, message: "Use sources(for:) instead")
    public static func sources() -> [ScreenShareSource] {
        return [displayIDs().map { ScreenShareSource.display(id: $0) },
                windowIDs().map { ScreenShareSource.window(id: $0) }].flatMap { $0 }
    }

    @available(*, deprecated, message: "Use sources(for:) instead")
    public static func displayIDs() -> [CGDirectDisplayID] {
        _displayIDs()
    }

    @available(*, deprecated, message: "Use sources(for:) instead")
    public static func windowIDs(includeCurrentProcess: Bool = false) -> [CGWindowID] {
        _windowIDs(includeCurrentProcess: includeCurrentProcess)
    }

    internal static func _displayIDs() -> [CGDirectDisplayID] {

        var displayCount: UInt32 = 0
        var activeCount: UInt32 = 0

        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else {
            return []
        }

        var displayIDList = [CGDirectDisplayID](repeating: kCGNullDirectDisplay, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &(displayIDList), &activeCount) == .success else {
            return []
        }

        return displayIDList
    }

    internal static func _windowIDs(includeCurrentProcess: Bool = false) -> [CGWindowID] {
        //
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly,
                                               .excludeDesktopElements ], kCGNullWindowID)! as Array

        return list
            .filter {
                // window layer needs to be 0
                guard let windowLayer = $0.object(forKey: kCGWindowLayer) as? NSNumber,
                      windowLayer.intValue == 0 else {
                    return false
                }

                // remove windows that don't have an associated bundleIdentifier
                guard let pid = ($0.object(forKey: kCGWindowOwnerPID) as? NSNumber)?.int32Value as? pid_t,
                      let app = NSRunningApplication(processIdentifier: pid),
                      app.bundleIdentifier != nil else {
                    return false
                }

                if !includeCurrentProcess {
                    // remove windows that are from current application
                    guard app.bundleIdentifier != Bundle.main.bundleIdentifier else {
                        return false
                    }
                }

                return true
            }
            .map { $0.object(forKey: kCGWindowNumber) as? NSNumber }.compactMap { $0 }.map { $0.uint32Value }
    }
}

#endif
