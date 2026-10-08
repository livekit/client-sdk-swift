/*
 * Copyright 2026 LiveKit
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

import AVFoundation
import Foundation

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

internal import LiveKitWebRTC

#if os(macOS)

@available(macOS 12.3, *)
public class MacOSScreenCapturer: ScreenCapturer, @unchecked Sendable {
    // TODO: Make it possible to change dynamically
    public let captureSource: MacOSScreenCaptureSource?

    init(delegate: LKRTCVideoCapturerDelegate, captureSource: MacOSScreenCaptureSource, options: ScreenShareCaptureOptions) {
        self.captureSource = captureSource
        super.init(delegate: delegate, options: options)
    }

    override public func startCapture() async throws -> Bool {
        do {
            return try await performStartCapture()
        } catch {
            // Balance the counter so a subsequent startCapture() can retry.
            try? await stopCapture()
            throw error
        }
    }

    private func performStartCapture() async throws -> Bool {
        let didStart = try await super.startCapture()

        // Already started
        guard didStart else { return false }

        guard let captureSource else {
            log("captureSource is nil", .error)
            throw LiveKitError(.invalidState, message: "captureSource is nil")
        }

        let filter: SCContentFilter
        if let windowSource = captureSource as? MacOSWindow,
           let nativeWindowSource = windowSource.nativeType as? SCWindow
        {
            filter = SCContentFilter(desktopIndependentWindow: nativeWindowSource)
        } else if let displaySource = captureSource as? MacOSDisplay,
                  let content = displaySource.scContent as? SCShareableContent,
                  let nativeDisplay = displaySource.nativeType as? SCDisplay
        {
            let includedApps = options.includeCurrentApplication ?
                content.applications :
                content.applications.filter { app in Bundle.main.bundleIdentifier != app.bundleIdentifier }

            let excludedWindows = content.windows.filter { window in options.excludeWindowIDs.contains(window.windowID) }

            filter = SCContentFilter(display: nativeDisplay, including: includedApps, exceptingWindows: excludedWindows)
        } else {
            log("Unable to resolve SCContentFilter", .error)
            throw LiveKitError(.invalidState, message: "Unable to resolve SCContentFilter")
        }

        let configuration = SCStreamConfiguration()

        let mainDisplay = CGMainDisplayID()
        // try to capture in max resolution
        configuration.width = CGDisplayPixelsWide(mainDisplay) * 2
        configuration.height = CGDisplayPixelsHigh(mainDisplay) * 2

        configuration.scalesToFit = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = options.showCursor

        if #available(macOS 13.0, *) {
            configuration.capturesAudio = options.appAudio
        }

        let stream = try makeStream(filter: filter, configuration: configuration)
        try await stream.startCapture()

        return true
    }

    override public func stopCapture() async throws -> Bool {
        let didStop = try await super.stopCapture()

        // Already stopped
        guard didStop else { return false }

        await teardownStream()

        return true
    }
}

@available(macOS 12.3, *)
public extension LocalVideoTrack {
    @objc
    @available(*, deprecated, message: "Blocks the calling thread until WebRTC's factory responds; use the async variant instead.")
    static func createMacOSScreenShareTrack(name: String = Track.screenShareVideoName,
                                            source: MacOSScreenCaptureSource,
                                            options: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                                            reportStatistics: Bool = false) -> LocalVideoTrack
    {
        _createMacOSScreenShareTrack(name: name, source: source, options: options, reportStatistics: reportStatistics)
    }

    /// Creates a macOS screen-share track on the RTC executor: the calling task suspends
    /// instead of blocking its thread on WebRTC's factory.
    static func createMacOSScreenShareTrack(name: String = Track.screenShareVideoName,
                                            source: MacOSScreenCaptureSource,
                                            options: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                                            reportStatistics: Bool = false) async -> LocalVideoTrack
    {
        // MacOSScreenCaptureSource is not Sendable; the capturer takes sole ownership on the executor.
        nonisolated(unsafe) let source = source
        return await RTC.run { _createMacOSScreenShareTrack(name: name, source: source, options: options, reportStatistics: reportStatistics) }
    }

    internal static func _createMacOSScreenShareTrack(name: String,
                                                      source: MacOSScreenCaptureSource,
                                                      options: ScreenShareCaptureOptions,
                                                      reportStatistics: Bool) -> LocalVideoTrack
    {
        let videoSource = RTC.createVideoSource(forScreenShare: true)
        let capturer = MacOSScreenCapturer(delegate: videoSource, captureSource: source, options: options)
        return LocalVideoTrack(name: name,
                               source: .screenShareVideo,
                               capturer: capturer,
                               videoSource: videoSource,
                               reportStatistics: reportStatistics)
    }
}

@objc
public enum MacOSScreenShareSourceType: Int, Sendable {
    case any
    case display
    case window
}

@objc
public protocol MacOSScreenCaptureSource: AnyObject {}

@objcMembers
public class MacOSRunningApplication: NSObject {
    public let processID: pid_t
    public let bundleIdentifier: String
    public let applicationName: String

    public let nativeType: Any?

    @available(macOS 12.3, *)
    init?(from scRunningApplication: SCRunningApplication?) {
        guard let scRunningApplication else { return nil }
        bundleIdentifier = scRunningApplication.bundleIdentifier
        applicationName = scRunningApplication.applicationName
        processID = scRunningApplication.processID
        nativeType = scRunningApplication
    }

    init?(from processID: pid_t?) {
        guard let processID,
              let app = NSRunningApplication(processIdentifier: processID) else { return nil }

        self.processID = processID
        bundleIdentifier = app.bundleIdentifier ?? ""
        applicationName = app.localizedName ?? ""
        nativeType = nil
    }
}

@objcMembers
public class MacOSWindow: NSObject, MacOSScreenCaptureSource {
    public let windowID: CGWindowID
    public let frame: CGRect
    public let title: String?
    public let windowLayer: Int
    public let owningApplication: MacOSRunningApplication?
    public let isOnScreen: Bool
    public let nativeType: Any?

    @available(macOS 12.3, *)
    init(from scWindow: SCWindow) {
        windowID = scWindow.windowID
        frame = scWindow.frame
        title = scWindow.title
        windowLayer = scWindow.windowLayer
        owningApplication = MacOSRunningApplication(from: scWindow.owningApplication)
        isOnScreen = scWindow.isOnScreen
        nativeType = scWindow
    }

    @objc(initFromWindowID:)
    init(from windowID: CGWindowID) {
        self.windowID = windowID

        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)! as Array

        guard let info = list.first as? NSDictionary else {
            fatalError("Window information not available")
        }

        frame = {
            guard let dict = info.object(forKey: kCGWindowBounds) as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dict)
            else {
                //
                return CGRect()
            }

            return frame
        }()

        title = info.object(forKey: kCGWindowName) as? String
        windowLayer = (info.object(forKey: kCGWindowLayer) as? NSNumber)?.intValue ?? 0
        owningApplication = MacOSRunningApplication(from: (info.object(forKey: kCGWindowOwnerPID) as? NSNumber)?.int32Value as? pid_t)
        isOnScreen = (info.object(forKey: kCGWindowIsOnscreen) as? NSNumber)?.boolValue ?? false
        nativeType = nil
    }
}

@objcMembers
public class MacOSDisplay: NSObject, MacOSScreenCaptureSource {
    public let displayID: CGDirectDisplayID
    public let width: Int
    public let height: Int
    public let frame: CGRect

    public let nativeType: Any?
    public let scContent: Any?

    @available(macOS 12.3, *)
    init(from scDisplay: SCDisplay, content: SCShareableContent) {
        displayID = scDisplay.displayID
        width = scDisplay.width
        height = scDisplay.height
        frame = scDisplay.frame
        nativeType = scDisplay
        scContent = content
    }

    // legacy
    init(from displayID: CGDirectDisplayID) {
        self.displayID = displayID
        width = CGDisplayPixelsWide(displayID)
        height = CGDisplayPixelsHigh(displayID)
        frame = CGRect(x: 0,
                       y: 0,
                       width: width,
                       height: height)
        nativeType = nil
        scContent = nil
    }
}

// MARK: - Filter extension

public extension MacOSWindow {
    /// Source is related to current running application
    @objc
    var isCurrentApplication: Bool {
        owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}

// MARK: - Enumerate sources

@available(macOS 12.3, *)
public extension MacOSScreenCapturer {
    internal static let queue = DispatchQueue(label: "LiveKitSDK.MacOSScreenCapturer.sources", qos: .default)

    /// Convenience method to get a ``MacOSDisplay`` of the main display.
    @objc
    static func mainDisplaySource() async throws -> MacOSDisplay {
        let displaySources = try await sources(for: .display)

        guard let source = displaySources.compactMap({ $0 as? MacOSDisplay }).first(where: { $0.displayID == CGMainDisplayID() }) else {
            throw LiveKitError(.invalidState, message: "Main display source not found")
        }

        return source
    }

    /// Enumerate ``MacOSDisplay`` or ``MacOSWindow`` sources.
    @objc
    static func sources(for type: MacOSScreenShareSourceType, includeCurrentApplication: Bool = false) async throws -> [MacOSScreenCaptureSource] {
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
    static func displaySources() async throws -> [MacOSDisplay] {
        let result = try await sources(for: .display)
        // Cast
        return result.compactMap { $0 as? MacOSDisplay }
    }

    @objc
    static func windowSources() async throws -> [MacOSWindow] {
        let result = try await sources(for: .window)
        // Cast
        return result.compactMap { $0 as? MacOSWindow }
    }
}

#endif
