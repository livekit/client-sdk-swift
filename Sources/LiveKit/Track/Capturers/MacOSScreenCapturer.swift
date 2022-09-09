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
}

#if os(macOS)

extension ScreenShareSource {
    public static let mainDisplay: ScreenShareSource = .display(id: CGMainDisplayID())
}

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

public class MacOSScreenCapturer: VideoCapturer {

    private let capture = DispatchQueue(label: "LiveKitSDK.macOSScreenCapturer", qos: .default)
    private let capturer = Engine.createVideoCapturer()

    // TODO: Make it possible to change dynamically
    public var source: ScreenShareSource

    // used for display capture
    private lazy var session: AVCaptureSession = {
        let session = AVCaptureSession()
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: capture)
        return session
    }()

    // used for window capture
    private var dispatchSourceTimer: DispatchQueueTimer?

    private var storedArView: Any?
    @available(macOS 12.3, *)
    var arView: SCStream? {
        get {
            return storedArView as? SCStream
        }
        set(newArView) {
            storedArView = newArView as Any
        }
    }

    private func startDispatchSourceTimer() {
        stopDispatchSourceTimer()
        let timeInterval: TimeInterval = 1 / Double(options.fps)
        dispatchSourceTimer = DispatchQueueTimer(timeInterval: timeInterval, queue: capture)
        dispatchSourceTimer?.handler = onDispatchSourceTimer
        dispatchSourceTimer?.resume()
    }

    private func stopDispatchSourceTimer() {
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
        self.options = options
        super.init(delegate: delegate)
    }

    private func onDispatchSourceTimer() {

        guard case .started = self.captureState,
              case .window(let windowId) = source else { return }

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

        super.startCapture().then(on: queue) { didStart -> Bool in

            guard didStart else {
                // already started
                return false
            }

            if #available(macOS 12.3, *) {
                //
                //                let filter = SCContentFilter(desktopIndependentWindow: window)
                Task {
                    print("capture: start")

                    do {
                        //                    let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                        //                    let display = c.displays.first!
                        //                        print("capture: display \(display)")
                        //
                        //                    let filter = SCContentFilter(display: display, excludingWindows: [])
                        //                    let configuration = SCStreamConfiguration()
                        //                    configuration.showsCursor = true
                        //                    configuration.width = 100
                        //                    configuration.height = 100
                        //
                        let windows: [SCWindow] = try await SCShareableContent.current.windows

                        guard let window = windows.first(where: { $0.owningApplication?.applicationName == "Google Chrome" }) else { return }

                        let filter = SCContentFilter(desktopIndependentWindow: window)

                        let configuration = SCStreamConfiguration()
                        configuration.width = Int(window.frame.width)
                        configuration.height = Int(window.frame.height)
                        configuration.scalesToFit = true
                        // configuration.showsCursor = true

                        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.capture)
                        try await stream.startCapture()
                        print("capture: started")

                        self.storedArView = stream
                    } catch let error {
                        print("capture: error: \(error)")
                    }
                }
                //
                //                let configuration = SCStreamConfiguration()
                ////                configuration.width = Int(window.frame.width)
                ////                configuration.height = Int(window.frame.height)
                //                configuration.showsCursor = true
                //                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                //                stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: capture)
                //                stream.startCapture()

            } else {
                // legacy support

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
            }

            return true
        }
    }

    public override func stopCapture() -> Promise<Bool> {

        super.stopCapture().then(on: queue) { didStop -> Bool in

            guard didStop else {
                // already stopped
                return false
            }

            if case .display = self.source {
                self.session.stopRunning()
            } else if case .window = self.source {
                self.stopDispatchSourceTimer()
            }

            return true
        }
    }

    private func capture(_ sampleBuffer: CMSampleBuffer) {

        delegate?.capturer(capturer, didCapture: sampleBuffer) { sourceDimensions in

            let targetDimensions = sourceDimensions
                .aspectFit(size: self.options.dimensions.max)
                .toEncodeSafeDimensions()

            defer { self.dimensions = targetDimensions }

            guard let videoSource = self.delegate as? RTCVideoSource else { return }
            // self.log("adaptOutputFormat to: \(targetDimensions) fps: \(self.options.fps)")

            videoSource.adaptOutputFormat(toWidth: targetDimensions.width,
                                          height: targetDimensions.height,
                                          fps: Int32(self.options.fps))
        }
    }
}

// MARK: - SCStreamOutput

@available(macOS 12.3, *)
extension MacOSScreenCapturer: SCStreamOutput {

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        print("capture: got buffer")
        capture(sampleBuffer)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension MacOSScreenCapturer: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {

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
}

#endif
