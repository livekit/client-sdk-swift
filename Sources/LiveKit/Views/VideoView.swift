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
import MetalKit

/// A ``NativeViewType`` that conforms to ``RTCVideoRenderer``.
public typealias NativeRendererView = NativeViewType & RTCVideoRenderer

public class VideoView: NativeView, Loggable {

    private static let mirrorTransform = CATransform3DMakeScale(-1.0, 1.0, 1.0)

    /// A set of bool values describing the state of rendering.
    public struct RenderState: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// Received first frame and already rendered to the ``VideoView``.
        /// This can be used to trigger smooth transition of the UI.
        static let didRenderFirstFrame  = RenderState(rawValue: 1 << 0)
        /// ``VideoView`` skipped rendering of a frame that could lead to crashes.
        static let didSkipUnsafeFrame   = RenderState(rawValue: 1 << 1)
    }

    public internal(set) var renderState = RenderState() {
        didSet {
            guard oldValue != renderState else { return }
            guard let track = track else { return }
            track.notify { $0.track(track, videoView: self, didUpdate: self.renderState) }
        }
    }

    public enum LayoutMode: String, Codable, CaseIterable {
        case fit
        case fill
    }

    public enum MirrorMode: String, Codable, CaseIterable {
        case auto
        case off
        case mirror
    }

    /// Layout ``ContentMode`` of the ``VideoView``.
    public var layoutMode: LayoutMode = .fill {
        didSet {
            guard oldValue != layoutMode else { return }
            safeMarkNeedsLayout()
        }
    }

    /// Flips the video horizontally, useful for local VideoViews.
    /// Known Issue: this will not work when os is macOS and ``preferMetal`` is false.
    public var mirrorMode: MirrorMode = .auto {
        didSet {
            guard oldValue != mirrorMode else { return }
            safeMarkNeedsLayout()
        }
    }

    /// OpenGL is deprecated and the SDK prefers to use Metal by default.
    /// Setting false when creating ``VideoView`` will force to use OpenGL.
    public var preferMetal: Bool = true {
        didSet {
            guard oldValue != preferMetal else { return }
            reCreateNativeRenderer()
        }
    }

    /// Size of this view (used to notify delegates)
    /// usually should be equal to `frame.size`
    public internal(set) var viewSize: CGSize {
        didSet {
            guard oldValue != viewSize else { return }
            // notify viewSize update
            guard let track = track else { return }
            track.notify { $0.track(track, videoView: self, didUpdate: self.viewSize) }
        }
    }

    /// Calls addRenderer and/or removeRenderer internally for convenience.
    private weak var oldTrack: VideoTrack?
    public weak var track: VideoTrack? {
        didSet {
            guard !(oldValue?.isEqual(track) ?? false) else { return }
            oldTrack = oldValue
            syncRendererAttach()
            safeMarkNeedsLayout()
        }
    }

    public override var isHidden: Bool {
        didSet {
            guard oldValue != isHidden else { return }
            syncRendererAttach()
            safeMarkNeedsLayout()
        }
    }

    private var isDeinit: Bool = false
    private var previousShouldAttach: Bool = false

    private func syncRendererAttach() {

        let shouldAttach = (track != nil && !isHidden && !isDeinit)

        if !(oldTrack?.isEqual(track) ?? false) {

            if let oldTrack = oldTrack {
                self.oldTrack = nil

                log("removing previous renderer")
                oldTrack.remove(renderer: self)

                // CapturerDelegate
                if let localTrack = oldTrack as? LocalVideoTrack {
                    localTrack.capturer.remove(delegate: self)
                }

                // notify detach
                oldTrack.notify { [weak oldTrack] (delegate) -> Void in
                    guard let oldValue = oldTrack else { return }
                    delegate.track(oldValue, didDetach: self)
                }
            }

            if let track = track {
                // CapturerDelegate
                if let localTrack = track as? LocalVideoTrack {
                    localTrack.capturer.add(delegate: self)
                }

                // notify attach
                track.notify { [weak track] (delegate) -> Void in
                    guard let track = track else { return }
                    delegate.track(track, didAttach: self)
                }

            } else {
                // if nil is set, clear out the renderer
                // DispatchQueue.webRTC.sync { nativeRenderer.renderFrame(nil) }
                log("clearing renderState")
                renderState = []
            }
        }

        if previousShouldAttach != shouldAttach {
            previousShouldAttach = shouldAttach

            if shouldAttach {

                log("attaching renderer")
                if let track = track {
                    track.add(renderer: self)
                }
            } else {
                log("detaching renderer")
                guard let track = track else {
                    log("track is nil")
                    // Possibly Track was released first
                    return
                }

                track.remove(renderer: self)
            }
        }
    }

    private var nativeRenderer: NativeRendererView

    public init(frame: CGRect = .zero, preferMetal: Bool = true) {
        self.viewSize = frame.size
        self.preferMetal = preferMetal
        self.nativeRenderer = VideoView.createNativeRendererView(preferMetal: preferMetal)
        super.init(frame: frame)
        #if os(iOS)
        self.clipsToBounds = true
        #endif
        addSubview(nativeRenderer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        log()
    }

    override func shouldLayout() {
        super.shouldLayout()

        // this should never happen
        dispatchPrecondition(condition: .onQueue(.main))

        defer {
            let size = self.frame.size
            DispatchQueue.main.async {
                self.viewSize = size
            }

            track?.notify { [weak track] in
                guard let track = track else { return }
                $0.track(track, videoView: self, didLayout: size)
            }
        }

        guard !isHidden else {
            // skip following layout logic if hidden
            log("skipping layout logic")
            return
        }

        // dimensions are required to continue computation
        guard let dimensions = DispatchQueue.mainSafeSync(execute: { track?.dimensions }) else {
            log("dimensions are nil, cannot layout without dimensions")
            return
        }

        var size = frame.size
        let wDim = CGFloat(dimensions.width)
        let hDim = CGFloat(dimensions.height)
        let wRatio = size.width / wDim
        let hRatio = size.height / hDim

        if .fill == layoutMode ? hRatio > wRatio : hRatio < wRatio {
            size.width = size.height / hDim * wDim
        } else if .fill == layoutMode ? wRatio > hRatio : wRatio < hRatio {
            size.height = size.width / wDim * hDim
        }

        // center layout
        // DispatchQueue.webRTC.sync {
        nativeRenderer.frame = CGRect(x: -((size.width - frame.size.width) / 2),
                                      y: -((size.height - frame.size.height) / 2),
                                      width: size.width,
                                      height: size.height)

        // nativeRenderer.wantsLayer = true
        // nativeRenderer.layer!.borderColor = NSColor.red.cgColor
        // nativeRenderer.layer!.borderWidth = 3

        if shouldMirror() {
            #if os(macOS)
            // this is required for macOS
            nativeRenderer.set(anchorPoint: CGPoint(x: 0.5, y: 0.5))
            nativeRenderer.wantsLayer = true
            nativeRenderer.layer!.sublayerTransform = VideoView.mirrorTransform
            #elseif os(iOS)
            nativeRenderer.layer.transform = VideoView.mirrorTransform
            #endif
        } else {
            #if os(macOS)
            nativeRenderer.layer?.sublayerTransform = CATransform3DIdentity
            #elseif os(iOS)
            nativeRenderer.layer.transform = CATransform3DIdentity
            #endif
        }
    }

    private func reCreateNativeRenderer() {
        // Save current track if exists
        let currentTrack = self.track
        // Remove track (notify delegates)
        self.track = nil
        // Remove the renderer view
        nativeRenderer.removeFromSuperview()
        // Clear the renderState
        renderState = []
        // Re-create renderer view
        nativeRenderer = VideoView.createNativeRendererView(preferMetal: preferMetal)
        addSubview(nativeRenderer)
        // Set previous track to new renderer view
        self.track = currentTrack

    }
}

// MARK: - Private

private extension VideoView {

    func safeMarkNeedsLayout() {
        DispatchQueue.main.async { [weak self] in
            self?.markNeedsLayout()
        }
    }

    func shouldMirror() -> Bool {
        switch mirrorMode {
        case .auto:
            guard let localVideoTrack = track as? LocalVideoTrack,
                  let cameraCapturer = localVideoTrack.capturer as? CameraCapturer,
                  case .front = cameraCapturer.options.position else { return false }
            return true
        case .off: return false
        case .mirror: return true
        }
    }
}

// MARK: - RTCVideoRenderer

extension VideoView: RTCVideoRenderer {

    public func setSize(_ size: CGSize) {
        nativeRenderer.setSize(size)
    }

    public func renderFrame(_ frame: RTCVideoFrame?) {

        if let frame = frame {

            let dimensions = Dimensions(width: frame.width,
                                        height: frame.height)
                .apply(rotation: frame.rotation)

            guard dimensions.isRenderSafe else {
                log("Skipping render for dimension \(dimensions)", .warning)
                // renderState.insert(.didSkipUnsafeFrame)
                return
            }

            if track?.set(dimensions: dimensions) == true {
                safeMarkNeedsLayout()
            }

        } else {
            if track?.set(dimensions: nil) == true {
                safeMarkNeedsLayout()
            }
        }

        nativeRenderer.renderFrame(frame)
        // track?.set(videoFrame: frame)

        // layout after first frame has been rendered
        if !renderState.contains(.didRenderFirstFrame) {
            renderState.insert(.didRenderFirstFrame)
            log("Did render first frame")
            safeMarkNeedsLayout()
        }
    }
}

// MARK: - VideoCapturerDelegate

extension VideoView: VideoCapturerDelegate {

    public func capturer(_ capturer: VideoCapturer, didUpdate state: VideoCapturer.State) {
        if case .started = state {
            safeMarkNeedsLayout()
        }
    }
}

// MARK: - Static helper methods

extension VideoView {

    public static func isMetalAvailable() -> Bool {
        #if os(iOS)
        MTLCreateSystemDefaultDevice() != nil
        #elseif os(macOS)
        // same method used with WebRTC
        !MTLCopyAllDevices().isEmpty
        #endif
    }

    internal static func createNativeRendererView(preferMetal: Bool) -> NativeRendererView {

        DispatchQueue.mainSafeSync {
            let view: NativeRendererView
            #if os(iOS)
            // iOS --------------------
            if preferMetal && isMetalAvailable() {
                logger.log("Using RTCMTLVideoView for VideoView's Renderer", type: VideoView.self)
                let mtlView = RTCMTLVideoView()
                // use .fit here to match macOS behavior and
                // manually calculate .fill if necessary
                mtlView.contentMode = .scaleAspectFit
                mtlView.videoContentMode = .scaleAspectFit
                view = mtlView
            } else {
                logger.log("Using RTCEAGLVideoView for VideoView's Renderer", type: VideoView.self)
                let glView = RTCEAGLVideoView()
                glView.contentMode = .scaleAspectFit
                view = glView
            }
            #else
            // macOS --------------------
            if preferMetal && isMetalAvailable() {
                logger.log("Using RTCMTLNSVideoView for VideoView's Renderer", type: VideoView.self)
                view = RTCMTLNSVideoView()
            } else {
                logger.log("Using RTCNSGLVideoView for VideoView's Renderer", type: VideoView.self)
                let attributes: [NSOpenGLPixelFormatAttribute] = [
                    UInt32(NSOpenGLPFAAccelerated),
                    // The following attributes are from
                    // https://chromium.googlesource.com/external/webrtc/+/refs/heads/master/examples/objc/AppRTCMobile/mac/APPRTCViewController.m
                    UInt32(NSOpenGLPFADoubleBuffer),
                    UInt32(NSOpenGLPFADepthSize), UInt32(24),
                    UInt32(NSOpenGLPFAOpenGLProfile),
                    UInt32(NSOpenGLProfileVersion3_2Core),
                    UInt32(0)
                ]
                let pixelFormat = NSOpenGLPixelFormat(attributes: attributes)
                view = RTCNSGLVideoView(frame: .zero, pixelFormat: pixelFormat)!
            }
            #endif

            // extra checks for MTKView
            for subView in view.subviews {
                if let metal = subView as? MTKView {
                    #if os(iOS)
                    metal.contentMode = .scaleAspectFit
                    #elseif os(macOS)
                    metal.layerContentsPlacement = .scaleProportionallyToFit
                    #endif
                }
            }

            return view
        }
    }
}

#if os(macOS)
extension NSView {
    //
    // Converted to Swift + NSView from:
    // http://stackoverflow.com/a/10700737
    //
    func set(anchorPoint: CGPoint) {
        if let layer = self.layer {
            var newPoint = CGPoint(x: self.bounds.size.width * anchorPoint.x,
                                   y: self.bounds.size.height * anchorPoint.y)
            var oldPoint = CGPoint(x: self.bounds.size.width * layer.anchorPoint.x,
                                   y: self.bounds.size.height * layer.anchorPoint.y)

            newPoint = newPoint.applying(layer.affineTransform())
            oldPoint = oldPoint.applying(layer.affineTransform())

            var position = layer.position

            position.x -= oldPoint.x
            position.x += newPoint.x

            position.y -= oldPoint.y
            position.y += newPoint.y

            layer.position = position
            layer.anchorPoint = anchorPoint
        }
    }
}
#endif
