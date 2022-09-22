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
import ReplayKit
import Promises

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

// currently only used for macOS
public enum ScreenShareSource {
    case display(id: UInt32)
    case window(id: UInt32)
    // case window(id2: String)
}

#if os(macOS)

extension ScreenShareSource {
    public static let mainDisplay: ScreenShareSource = .display(id: CGMainDisplayID())
}

public class MacOSScreenCapturer: VideoCapturer {

    private let captureQueue = DispatchQueue(label: "LiveKitSDK.macOSScreenCapturer", qos: .default)
    private let capturer = Engine.createVideoCapturer()

    // TODO: Make it possible to change dynamically
    public let source: ScreenShareSource?
    public let scSource: MacOSScreenShareSource?

    private var _scStream: Any?
    @available(macOS 12.3, *)
    var scStream: SCStream? {
        get { _scStream as? SCStream }
        set { _scStream = newValue }
    }

    // MARK: - Legacy support

    // used for display capture
    private lazy var session: AVCaptureSession = {

        if #available(macOS 12.3, *) {
            // this should never happen
            fatalError("ScreenCaptureKit should be used for macOS 12.3+")
        }

        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: captureQueue)
        return session
    }()

    // used for window capture
    private var dispatchSourceTimer: DispatchQueueTimer?

    private func startDispatchSourceTimer() {

        if #available(macOS 12.3, *) {
            // this should never happen
            fatalError("ScreenCaptureKit should be used for macOS 12.3+")
        }

        stopDispatchSourceTimer()
        let timeInterval: TimeInterval = 1 / Double(options.fps)
        dispatchSourceTimer = DispatchQueueTimer(timeInterval: timeInterval, queue: captureQueue)
        dispatchSourceTimer?.handler = onDispatchSourceTimer
        dispatchSourceTimer?.resume()
    }

    private func stopDispatchSourceTimer() {

        if #available(macOS 12.3, *) {
            // this should never happen
            fatalError("ScreenCaptureKit should be used for macOS 12.3+")
        }

        if let timer = dispatchSourceTimer {
            timer.suspend()
            dispatchSourceTimer = nil
        }
    }

    /// The ``ScreenShareCaptureOptions`` used for this capturer.
    /// It is possible to modify the options but `restartCapture` must be called.
    public var options: ScreenShareCaptureOptions

    init(delegate: RTCVideoCapturerDelegate,
         source: ScreenShareSource,
         options: ScreenShareCaptureOptions) {
        self.source = source
        self.scSource = nil
        self.options = options
        super.init(delegate: delegate)
    }

    init(delegate: RTCVideoCapturerDelegate,
         scSource: MacOSScreenShareSource,
         options: ScreenShareCaptureOptions) {
        self.source = nil
        self.scSource = scSource
        self.options = options
        super.init(delegate: delegate)
    }

    private func onDispatchSourceTimer() {

        if #available(macOS 12.3, *) {
            // this should never happen
            fatalError("ScreenCaptureKit should be used for macOS 12.3+")
        }

        guard case .started = self.captureState,
              case .window(id: let windowId) = source else { return }

        guard let image = CGWindowListCreateImage(CGRect.null,
                                                  .optionIncludingWindow,
                                                  windowId, [.shouldBeOpaque,
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

        super.startCapture().then(on: queue) { didStart -> Promise<Bool> in

            guard didStart else {
                // already started
                return Promise(false)
            }

            if #available(macOS 12.3, *) {

                guard let windowSource = self.scSource as? MacOSWindow,
                      let nativeWindowSource = windowSource.nativeType as? SCWindow else {
                    return Promise(false)
                }

                return Promise<Bool>(on: self.queue) { success, failure in
                    Task {

                        do {
                            // let windows: [SCWindow] = try await SCShareableContent.current.windows
                            // let displays: [SCDisplay] = try await SCShareableContent.current.displays
                            // let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                            // guard let window = windows.first(where: { $0.owningApplication?.applicationName == "Google Chrome" }) else { return }

                            // let filter = SCContentFilter(desktopIndependentWindow: window)

                            // let window = content.windows.first { w in
                            // w.owningApplication?.applicationName == "Google Chrome"
                            // }!

                            // let excludedApps = content.applications.filter { app in
                            // Bundle.main.bundleIdentifier == app.bundleIdentifier
                            // }

                            // let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
                            let filter = SCContentFilter(desktopIndependentWindow: nativeWindowSource)

                            let configuration = SCStreamConfiguration()
                            configuration.width = Int(nativeWindowSource.frame.width * 2)
                            configuration.height = Int(nativeWindowSource.frame.height * 2)
                            configuration.scalesToFit = false
                            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(15))
                            configuration.queueDepth = 5
                            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

                            // configuration.showsCursor = true

                            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)
                            try await stream.startCapture()
                            print("capture: started")

                            self.scStream = stream
                            success(true)

                        } catch let error {
                            print("capture: error: \(error)")
                            failure(error)
                        }
                    }
                }

            } else {

                // legacy support

                return Promise<Bool>(on: self.queue) { () -> Bool in

                    if case .display(let displayID) = self.source {

                        // clear all previous inputs
                        for input in self.session.inputs {
                            self.session.removeInput(input)
                        }

                        // try to create a display input
                        guard let input = AVCaptureScreenInput(displayID: displayID) else {
                            // fail promise if displayID is invalid
                            throw TrackError.state(message: "Failed to create screen input with displayID: \(displayID)")
                        }

                        input.minFrameDuration = CMTimeMake(value: 1, timescale: Int32(self.options.fps))
                        input.capturesCursor = true
                        input.capturesMouseClicks = true
                        self.session.addInput(input)

                        self.session.startRunning()

                    } else if case .window = self.source {
                        self.startDispatchSourceTimer()
                    }

                    return true
                }
            }
        }
    }

    public override func stopCapture() -> Promise<Bool> {

        super.stopCapture().then(on: queue) { didStop -> Promise<Bool> in

            guard didStop else {
                // already stopped
                return Promise(false)
            }

            if #available(macOS 12.3, *) {

                return Promise<Bool>(on: self.queue) { f, r in
                    Task {
                        do {
                            try await self.scStream?.stopCapture()
                            f(true)
                        } catch let error {
                            r(error)
                        }
                    }
                }

            } else {

                // legacy support

                return Promise<Bool>(on: self.queue) { () -> Bool in
                    //
                    if case .display = self.source {
                        self.session.stopRunning()
                    } else if case .window = self.source {
                        self.stopDispatchSourceTimer()
                    }

                    return true
                }
            }
        }
    }

    private func capture(_ sampleBuffer: CMSampleBuffer, cropRect: CGRect? = nil) {

        guard let delegate = delegate else { return }

        // Get the pixel buffer that contains the image data.
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(timeStamp) * Double(NSEC_PER_SEC))

        let pixelWidth = CVPixelBufferGetWidth(pixelBuffer)
        let pixelHeight = CVPixelBufferGetHeight(pixelBuffer)

        DispatchQueue.webRTC.sync {

            let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer,
                                             adaptedWidth: Int32(cropRect!.width) * 2,
                                             adaptedHeight: Int32(cropRect!.height) * 2,
                                             cropWidth: Int32(cropRect!.width) * 2,
                                             cropHeight: Int32(cropRect!.height) * 2,
                                             cropX: Int32(cropRect!.origin.x),
                                             cropY: Int32(cropRect!.origin.y))

            let rtcFrame = RTCVideoFrame(buffer: rtcBuffer,
                                         rotation: ._0,
                                         timeStampNs: timeStampNs)

            delegate.capturer(capturer, didCapture: rtcFrame)
        }
        //        delegate?.capturer(capturer, didCapture: sampleBuffer) { sourceDimensions in
        //
        //            let targetDimensions = sourceDimensions
        //                .aspectFit(size: self.options.dimensions.max)
        //                .toEncodeSafeDimensions()
        //
        //            defer { self.dimensions = sourceDimensions }
        //
        //            guard let videoSource = self.delegate as? RTCVideoSource else { return }
        //            // self.log("adaptOutputFormat to: \(targetDimensions) fps: \(self.options.fps)")
        //
        //            videoSource.adaptOutputFormat(toWidth: targetDimensions.width,
        //                                          height: targetDimensions.height,
        //                                          fps: Int32(self.options.fps))
        //        }
    }
}

// MARK: - SCStreamOutput

@available(macOS 12.3, *)
extension MacOSScreenCapturer: SCStreamDelegate {

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("capture: didStopWithError \(error)")
    }
}

@available(macOS 12.3, *)
extension MacOSScreenCapturer: SCStreamOutput {

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {

        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                             createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first else { return }

        // Validate the status of the frame. If it isn't `.complete`, return nil.
        guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete else { return }

        //        // Get the pixel buffer that contains the image data.
        //        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        //
        //        // Get the backing IOSurface.
        //        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        //        let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)
        //
        // Retrieve the content rectangle, scale, and scale factor.
        guard let contentRectDict = attachments[.contentRect],
              let contentRect = CGRect(dictionaryRepresentation: contentRectDict as! CFDictionary),
              let contentScale = attachments[.contentScale] as? CGFloat,
              let scaleFactor = attachments[.scaleFactor] as? CGFloat else { return }

        //        print("capture: got surface: \(contentRect) -> \(width)x\(height)")

        capture(sampleBuffer, cropRect: contentRect)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension MacOSScreenCapturer: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {

        if #available(macOS 12.3, *) {
            // this should never happen
            fatalError("ScreenCaptureKit should be used for macOS 12.3+")
        }

        capture(sampleBuffer)
    }
}

extension LocalVideoTrack {
    /// Creates a track that captures the whole desktop screen
    public static func createMacOSScreenShareTrack(name: String = Track.screenShareVideoName,
                                                   source: ScreenShareSource = .mainDisplay,
                                                   options: ScreenShareCaptureOptions = ScreenShareCaptureOptions()) -> LocalVideoTrack {
        let videoSource = Engine.createVideoSource(forScreenShare: true)
        let capturer = MacOSScreenCapturer(delegate: videoSource, source: source, options: options)
        return LocalVideoTrack(
            name: name,
            source: .screenShareVideo,
            capturer: capturer,
            videoSource: videoSource
        )
    }

    public static func createMacOSScreenShareTrack(name: String = Track.screenShareVideoName,
                                                   source: MacOSScreenShareSource,
                                                   options: ScreenShareCaptureOptions = ScreenShareCaptureOptions()) -> LocalVideoTrack {
        let videoSource = Engine.createVideoSource(forScreenShare: true)
        let capturer = MacOSScreenCapturer(delegate: videoSource, scSource: source, options: options)
        return LocalVideoTrack(
            name: name,
            source: .screenShareVideo,
            capturer: capturer,
            videoSource: videoSource
        )
    }
}

#endif

public enum MacOSScreenShareSourceType {
    case any
    case display
    case window
}

public protocol MacOSScreenShareSource {

}

@objc
public class MacOSRunningApplication: NSObject {
    let bundleIdentifier: String
    let applicationName: String
    let processID: pid_t
    let nativeType: Any?

    internal init(bundleIdentifier: String,
                  applicationName: String,
                  processID: pid_t,
                  nativeType: Any?) {

        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.processID = processID
        self.nativeType = nativeType
    }

    @available(macOS 12.3, *)
    internal init?(from scRunningApplication: SCRunningApplication?) {
        guard let scRunningApplication = scRunningApplication else { return nil }
        self.bundleIdentifier = scRunningApplication.bundleIdentifier
        self.applicationName = scRunningApplication.applicationName
        self.processID = scRunningApplication.processID
        self.nativeType = scRunningApplication
    }
}

@objc
public class MacOSWindow: NSObject, MacOSScreenShareSource {
    let windowID: CGWindowID
    let frame: CGRect
    let title: String?
    let windowLayer: Int
    let owningApplication: MacOSRunningApplication?
    let isOnScreen: Bool
    let nativeType: Any?

    internal init(windowID: CGWindowID,
                  frame: CGRect,
                  title: String?,
                  windowLayer: Int,
                  owningApplication: MacOSRunningApplication?,
                  isOnScreen: Bool,
                  nativeType: Any?) {

        self.windowID = windowID
        self.frame = frame
        self.title = title
        self.windowLayer = windowLayer
        self.owningApplication = owningApplication
        self.isOnScreen = isOnScreen
        self.nativeType = nativeType
    }

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
}

@objc
public class MacOSDisplay: NSObject, MacOSScreenShareSource {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let frame: CGRect
    let nativeType: Any?

    internal init(displayID: CGDirectDisplayID,
                  width: Int,
                  height: Int,
                  frame: CGRect,
                  nativeType: Any?) {

        self.displayID = displayID
        self.width = width
        self.height = height
        self.frame = frame
        self.nativeType = nativeType
    }

    @available(macOS 12.3, *)
    internal init(from scDisplay: SCDisplay) {
        self.displayID = scDisplay.displayID
        self.width = scDisplay.width
        self.height = scDisplay.height
        self.frame = scDisplay.frame
        self.nativeType = scDisplay
    }
}

// @available(macOS 12.3, *)
// extension SCRunningApplication: MacOSRunningApplication {
//    //
// }
//
// @available(macOS 12.3, *)
// extension SCWindow: MacOSWindow {
//    // typealias ReturnType = SCRunningApplication
// }

// MARK: - Enumerate sources

extension MacOSScreenCapturer {

    public static func sources(for type: MacOSScreenShareSourceType) -> Promise<[MacOSScreenShareSource]> {

        if #available(macOS 12.3, *) {
            return Promise<[MacOSScreenShareSource]> { fulfill, reject in
                Task {
                    do {
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        switch type {

                        case .any:
                            let displays = content.displays.map { MacOSDisplay(from: $0) }
                            let windows = content.windows.map { MacOSWindow(from: $0) }
                            fulfill(displays + windows)
                        case .display:
                            let displays = content.displays.map { MacOSDisplay(from: $0) }
                            fulfill(displays)
                        case .window:
                            let windows = content.windows.map { MacOSWindow(from: $0) }
                            fulfill(windows)
                        }

                    } catch let error {
                        reject(error)
                    }
                }
            }
        } else {
            // Fallback on earlier versions
            fatalError()
        }
    }
    public static func displaySources() -> Promise<[MacOSDisplay]> {
        //
        // let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // guard let window = windows.first(where: { $0.owningApplication?.applicationName == "Google Chrome" }) else { return }
        // let filter = SCContentFilter(desktopIndependentWindow: window)

        if #available(macOS 12.3, *) {

            return Promise<[MacOSDisplay]> { fulfill, reject in
                Task {
                    do {
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        let displays = content.displays.map { MacOSDisplay(from: $0) }
                        fulfill(displays)
                    } catch let error {
                        reject(error)
                    }
                }
            }
        } else {
            // Fallback on earlier versions
            fatalError()
        }
    }

    public static func windowSources() -> Promise<[MacOSWindow]> {

        if #available(macOS 12.3, *) {

            return Promise<[MacOSWindow]> { fulfill, reject in
                Task {
                    do {
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        let windows = content.windows.map { MacOSWindow(from: $0) }
                        fulfill(windows)
                    } catch let error {
                        reject(error)
                    }
                }
            }
        } else {
            // Fallback on earlier versions
            fatalError()
        }
        // guard let window = windows.first(where: { $0.owningApplication?.applicationName == "Google Chrome" }) else { return }

        // let filter = SCContentFilter(desktopIndependentWindow: window)

    }
}

// MARK: - Enumerate sources (Deprecated)

extension MacOSScreenCapturer {

    public static func sources() -> [ScreenShareSource] {
        return [displayIDs().map { ScreenShareSource.display(id: $0) },
                windowIDs().map { ScreenShareSource.window(id: $0) }].flatMap { $0 }
    }

    // gets a list of window IDs
    public static func windowIDs(includeCurrentProcess: Bool = false) -> [CGWindowID] {

        let currentPID = ProcessInfo.processInfo.processIdentifier

        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly,
                                               .excludeDesktopElements ], kCGNullWindowID)! as Array

        return list
            .filter {
                guard let windowLayer = $0.object(forKey: kCGWindowLayer) as? NSNumber,
                      windowLayer.intValue == 0 else { return false }

                if !includeCurrentProcess {
                    guard let windowOwnerPid = $0.object(forKey: kCGWindowOwnerPID) as? NSNumber,
                          windowOwnerPid.intValue != currentPID else { return false }
                }

                return true
            }
            .map { $0.object(forKey: kCGWindowNumber) as? NSNumber }.compactMap { $0 }.map { $0.uint32Value }
    }

    // gets a list of display IDs
    public static func displayIDs() -> [CGDirectDisplayID] {
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
}
