/*
 * Copyright 2024 LiveKit
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
import MetalKit

@_implementationOnly import WebRTC

/// A ``NativeViewType`` that conforms to ``RTCVideoRenderer``.
typealias NativeRendererView = LKRTCVideoRenderer & Mirrorable & NativeViewType
protocol Mirrorable {
    func set(mirrored: Bool)
}

@objc
public class VideoView: NativeView, Loggable {
    // MARK: - MulticastDelegate

    public let delegates = MulticastDelegate<VideoViewDelegate>()

    // MARK: - Static

    static let mirrorTransform = CATransform3DMakeScale(-1.0, 1.0, 1.0)
    private static let _freezeDetectThreshold = 2.0

    /// Specifies how to render the video withing the ``VideoView``'s bounds.
    @objc
    public enum LayoutMode: Int, Codable {
        /// Video will be fully visible within the ``VideoView``.
        case fit
        /// Video will fully cover up the ``VideoView``.
        case fill
    }

    @objc
    public enum MirrorMode: Int, Codable {
        /// Will mirror if the track is a front facing camera track.
        case auto
        case off
        case mirror
    }

    @objc
    public enum RenderMode: Int, Codable, CustomStringConvertible {
        case auto
        case metal
        case sampleBuffer

        public var description: String {
            switch self {
            case .auto: return ".auto"
            case .metal: return ".metal"
            case .sampleBuffer: return ".sampleBuffer"
            }
        }
    }

    /// ``LayoutMode-swift.enum`` of the ``VideoView``.
    @objc
    public var layoutMode: LayoutMode {
        get { _state.layoutMode }
        set { _state.mutate { $0.layoutMode = newValue } }
    }

    /// Flips the video horizontally, useful for local VideoViews.
    @objc
    public var mirrorMode: MirrorMode {
        get { _state.mirrorMode }
        set { _state.mutate { $0.mirrorMode = newValue } }
    }

    @objc
    public var renderMode: RenderMode {
        get { _state.renderMode }
        set { _state.mutate { $0.renderMode = newValue } }
    }

    /// Force video to be rotated to preferred ``VideoRotation``.
    public var rotationOverride: VideoRotation? {
        get { _state.rotationOverride }
        set { _state.mutate { $0.rotationOverride = newValue } }
    }

    /// Calls addRenderer and/or removeRenderer internally for convenience.
    @objc
    public weak var track: VideoTrack? {
        get { _state.track as? VideoTrack }
        set {
            _state.mutate {
                // reset states if track updated
                if !Self.track($0.track as? VideoTrack, isEqualWith: newValue) {
                    $0.renderDate = nil
                    $0.didRenderFirstFrame = false
                    $0.isRendering = false
                    $0.rendererSize = nil
                }
                $0.track = newValue
            }
        }
    }

    /// If set to false, rendering will be paused temporarily. Useful for performance optimizations with UICollectionViewCell etc.
    @objc
    public var isEnabled: Bool {
        get { _state.isEnabled }
        set { _state.mutate { $0.isEnabled = newValue } }
    }

    @objc
    override public var isHidden: Bool {
        get { _state.isHidden }
        set {
            _state.mutate { $0.isHidden = newValue }
            Task.detached { @MainActor in
                super.isHidden = newValue
            }
        }
    }

    @objc
    public var isDebugMode: Bool {
        get { _state.isDebugMode }
        set { _state.mutate { $0.isDebugMode = newValue } }
    }

    @objc
    public var isRendering: Bool { _state.isRendering }

    @objc
    public var didRenderFirstFrame: Bool { _state.didRenderFirstFrame }

    /// Access the internal AVSampleBufferDisplayLayer used for rendering.
    /// This is only available when the renderer is using AVSampleBufferDisplayLayer.
    /// Recommended to be accessed from main thread.
    public var avSampleBufferDisplayLayer: AVSampleBufferDisplayLayer? {
        guard let nr = nativeRenderer as? SampleBufferVideoRenderer else { return nil }
        return nr.sampleBufferDisplayLayer
    }

    // MARK: - Internal

    struct State: Equatable {
        weak var track: Track?
        var isEnabled: Bool = true
        var isHidden: Bool = false

        // layout related
        var viewSize: CGSize
        var rendererSize: CGSize?
        var didLayout: Bool = false
        var layoutMode: LayoutMode = .fill
        var mirrorMode: MirrorMode = .auto
        var renderMode: RenderMode = .auto
        var rotationOverride: VideoRotation?

        var isDebugMode: Bool = false

        // render states
        var renderDate: Date?
        var didRenderFirstFrame: Bool = false
        var isRendering: Bool = false

        // whether if current state should be rendering
        var shouldRender: Bool {
            track != nil && isEnabled && !isHidden
        }
    }

    var _state: StateSync<State>

    // MARK: - Private

    private var nativeRenderer: NativeRendererView?
    private var _debugTextView: TextView?

    // used for stats timer
    private lazy var _renderTimer = DispatchQueueTimer(timeInterval: 0.1)

    private let _fpsTimer = DispatchQueueTimer(timeInterval: 1, queue: .main)
    private var _currentFPS: Int = 0
    private var _frameCount: Int = 0

    override public init(frame: CGRect = .zero) {
        // should always be on main thread
        assert(Thread.current.isMainThread, "must be on the main thread")

        // initial state
        _state = StateSync(State(viewSize: frame.size))

        super.init(frame: frame)

        #if os(iOS)
            clipsToBounds = true
        #endif

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in

            guard let self else { return }

            let shouldRenderDidUpdate = newState.shouldRender != oldState.shouldRender
            let renderModeDidUpdate = newState.renderMode != oldState.renderMode

            // track was swapped
            let trackDidUpdate = !Self.track(oldState.track as? VideoTrack, isEqualWith: newState.track as? VideoTrack)

            // Enter .main only if the following conditions are met...
            if trackDidUpdate || shouldRenderDidUpdate || renderModeDidUpdate {
                Task.detached { @MainActor in

                    var didReCreateNativeRenderer = false

                    if trackDidUpdate || shouldRenderDidUpdate {
                        // clean up old track
                        if let track = oldState.track as? VideoTrack {
                            track.remove(videoRenderer: self)

                            if let nr = self.nativeRenderer {
                                self.log("removing nativeRenderer")
                                nr.removeFromSuperview()
                                self.nativeRenderer = nil
                            }

                            // CapturerDelegate
                            if let localTrack = track as? LocalVideoTrack {
                                localTrack.capturer.remove(delegate: self)
                            }
                        }

                        // set new track
                        if let track = newState.track as? VideoTrack, newState.shouldRender {
                            // re-create renderer on main thread
                            let nr = self.reCreateNativeRenderer()
                            didReCreateNativeRenderer = true

                            track.add(videoRenderer: self)

                            if let frame = track._state.videoFrame {
                                self.log("rendering cached frame tack: \(track._state.sid ?? "nil")")
                                nr.renderFrame(frame.toRTCType())
                                self.setNeedsLayout()
                            }

                            // CapturerDelegate
                            if let localTrack = track as? LocalVideoTrack {
                                localTrack.capturer.add(delegate: self)
                            }
                        }
                    }

                    if renderModeDidUpdate, !didReCreateNativeRenderer {
                        self.reCreateNativeRenderer()
                    }
                }
            }

            // isRendering updated
            if newState.isRendering != oldState.isRendering {
                self.log("isRendering \(oldState.isRendering) -> \(newState.isRendering)")

                if newState.isRendering {
                    self._renderTimer.restart()
                } else {
                    self._renderTimer.suspend()
                }

                self.delegates.notify(label: { "videoView.didUpdate isRendering: \(newState.isRendering)" }) {
                    $0.videoView?(self, didUpdate: newState.isRendering)
                }
            }

            // viewSize updated
            if newState.viewSize != oldState.viewSize {
                self.delegates.notify(label: { "videoView.didUpdate viewSize: \(newState.viewSize)" }) {
                    $0.videoView?(self, didUpdate: newState.viewSize)
                }
            }

            // toggle MTKView's isPaused property
            // https://developer.apple.com/documentation/metalkit/mtkview/1535973-ispaused
            // https://developer.apple.com/forums/thread/105252
            // nativeRenderer.asMetalView?.isPaused = !shouldAttach

            // layout is required if any of the following vars mutate
            if newState.isDebugMode != oldState.isDebugMode ||
                newState.layoutMode != oldState.layoutMode ||
                newState.mirrorMode != oldState.mirrorMode ||
                newState.renderMode != oldState.renderMode ||
                newState.rotationOverride != oldState.rotationOverride ||
                newState.didRenderFirstFrame != oldState.didRenderFirstFrame ||
                shouldRenderDidUpdate || trackDidUpdate
            {
                // must be on main
                Task.detached { @MainActor in
                    self.setNeedsLayout()
                }
            }

            if newState.isDebugMode != oldState.isDebugMode {
                // fps timer
                if newState.isDebugMode {
                    self._fpsTimer.restart()
                } else {
                    self._fpsTimer.suspend()
                }
            }
        }

        _renderTimer.handler = { [weak self] in

            guard let self else { return }

            if self._state.isRendering, let renderDate = self._state.renderDate {
                let diff = Date().timeIntervalSince(renderDate)
                if diff >= Self._freezeDetectThreshold {
                    self._state.mutate { $0.isRendering = false }
                }
            }
        }

        _fpsTimer.handler = { [weak self] in

            guard let self else { return }

            self._currentFPS = self._frameCount
            self._frameCount = 0

            self.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        log()
    }

    override func performLayout() {
        super.performLayout()

        // should always be on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        let state = _state.copy()

        defer {
            let viewSize = frame.size

            if state.viewSize != viewSize || !state.didLayout {
                // mutate if required
                _state.mutate {
                    $0.viewSize = viewSize
                    $0.didLayout = true
                }
            }
        }

        if state.isDebugMode {
            let _trackSid = state.track?.sid ?? "nil"
            let _dimensions = state.track?.dimensions ?? .zero
            let _didRenderFirstFrame = state.didRenderFirstFrame ? "true" : "false"
            let _isRendering = state.isRendering ? "true" : "false"
            let _renderMode = String(describing: state.renderMode)
            let _viewCount = state.track?.videoRenderers.allObjects.count ?? 0
            let debugView = ensureDebugTextView()
            debugView.text = "#\(hashValue)\n" + "\(_trackSid)\n" + "\(_dimensions.width)x\(_dimensions.height)\n" + "isEnabled: \(isEnabled)\n" + "firstFrame: \(_didRenderFirstFrame)\n" + "isRendering: \(_isRendering)\n" + "renderMode: \(_renderMode)\n" + "viewCount: \(_viewCount)\n" + "FPS: \(_currentFPS)\n"
            debugView.frame = bounds
            #if os(iOS)
                debugView.layer.borderColor = (state.shouldRender ? UIColor.green : UIColor.red).withAlphaComponent(0.5).cgColor
                debugView.layer.borderWidth = 3
            #elseif os(macOS)
                debugView.wantsLayer = true
                debugView.layer!.borderColor = (state.shouldRender ? NSColor.green : NSColor.red).withAlphaComponent(0.5).cgColor
                debugView.layer!.borderWidth = 3
            #endif
        } else {
            if let debugView = _debugTextView {
                debugView.removeFromSuperview()
                _debugTextView = nil
            }
        }

        guard let track = state.track else {
            log("track is nil, cannot layout without track", .warning)
            return
        }

        // dimensions are required to continue computation
        guard let dimensions = track._state.dimensions else {
            // log("dimensions are nil, cannot layout without dimensions, track: \(track)", .debug)
            return
        }

        var size = frame.size
        let wDim = CGFloat(dimensions.width)
        let hDim = CGFloat(dimensions.height)
        let wRatio = size.width / wDim
        let hRatio = size.height / hDim

        if state.layoutMode == .fill ? hRatio > wRatio : hRatio < wRatio {
            size.width = size.height / hDim * wDim
        } else if state.layoutMode == .fill ? wRatio > hRatio : wRatio < hRatio {
            size.height = size.width / wDim * hDim
        }

        let rendererFrame = CGRect(x: -((size.width - frame.size.width) / 2),
                                   y: -((size.height - frame.size.height) / 2),
                                   width: size.width,
                                   height: size.height)

        if state.rendererSize != rendererFrame.size {
            // mutate if required
            _state.mutate { $0.rendererSize = rendererFrame.size }
        }

        // nativeRenderer.wantsLayer = true
        // nativeRenderer.layer!.borderColor = NSColor.red.cgColor
        // nativeRenderer.layer!.borderWidth = 3

        guard let nativeRenderer else { return }

        nativeRenderer.frame = rendererFrame

        if let mtlVideoView = nativeRenderer as? LKRTCMTLVideoView {
            if let rotationOverride = state.rotationOverride {
                mtlVideoView.rotationOverride = NSNumber(value: rotationOverride.rawValue)
            } else {
                mtlVideoView.rotationOverride = nil
            }
        }

        nativeRenderer.set(mirrored: shouldMirror())
    }
}

// MARK: - Private

private extension VideoView {
    private func ensureDebugTextView() -> TextView {
        if let view = _debugTextView { return view }
        let view = TextView()
        addSubview(view)
        _debugTextView = view
        return view
    }

    @discardableResult
    func reCreateNativeRenderer() -> NativeRendererView {
        // should always be on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        // create a new rendererView
        let newView = VideoView.createNativeRendererView(for: _state.renderMode)
        addSubview(newView)

        // keep the old rendererView
        let oldView = nativeRenderer
        nativeRenderer = newView

        if let oldView {
            // copy frame from old renderer
            newView.frame = oldView.frame
            // remove if existed
            oldView.removeFromSuperview()
        }

        // ensure debug info is most front
        if let view = _debugTextView {
            bringSubviewToFront(view)
        }

        return newView
    }

    func shouldMirror() -> Bool {
        switch _state.mirrorMode {
        case .auto:
            guard let localVideoTrack = _state.track as? LocalVideoTrack,
                  let cameraCapturer = localVideoTrack.capturer as? CameraCapturer,
                  case .front = cameraCapturer.options.position else { return false }
            return true
        case .off: return false
        case .mirror: return true
        }
    }
}

// MARK: - RTCVideoRenderer

extension VideoView: VideoRenderer {
    public var isAdaptiveStreamEnabled: Bool {
        _state.read { $0.didLayout && !$0.isHidden && $0.isEnabled }
    }

    public var adaptiveStreamSize: CGSize {
        _state.rendererSize ?? .zero
    }

    public func set(size: CGSize) {
        guard let nr = nativeRenderer else { return }
        nr.setSize(size)
    }

    public func render(frame: VideoFrame) {
        let state = _state.copy()

        // prevent any extra rendering if already !isEnabled etc.
        guard state.shouldRender, let nr = nativeRenderer else {
            log("canRender is false, skipping render...")
            return
        }

        var _needsLayout = false
        defer {
            if _needsLayout {
                Task.detached { @MainActor in
                    self.setNeedsLayout()
                }
            }
        }

        let rotation = state.rotationOverride ?? frame.rotation
        let dimensions = frame.dimensions.apply(rotation: rotation.toRTCType())

        guard dimensions.isRenderSafe else {
            log("skipping render for dimension \(dimensions)", .warning)
            // renderState.insert(.didSkipUnsafeFrame)
            return
        }

        if track?.set(dimensions: dimensions) == true {
            _needsLayout = true
        }

        nr.renderFrame(frame.toRTCType())

        // cache last rendered frame
        track?.set(videoFrame: frame)

        _state.mutate {
            $0.didRenderFirstFrame = true
            $0.isRendering = true
            $0.renderDate = Date()
        }

        if _state.isDebugMode {
            Task.detached { @MainActor in
                self._frameCount += 1
            }
        }
    }
}

// MARK: - VideoCapturerDelegate

extension VideoView: VideoCapturerDelegate {
    public func capturer(_: VideoCapturer, didUpdate state: VideoCapturer.CapturerState) {
        if case .started = state {
            Task.detached { @MainActor in
                self.setNeedsLayout()
            }
        }
    }
}

// MARK: - Internal

extension VideoView {
    static func track(_ track1: VideoTrack?, isEqualWith track2: VideoTrack?) -> Bool {
        // equal if both tracks are nil
        if track1 == nil, track2 == nil { return true }
        // not equal if a single track is nil
        guard let track1, let track2 else { return false }
        // use isEqual
        return track1.isEqual(track2)
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

    static func createNativeRendererView(for renderMode: VideoView.RenderMode) -> NativeRendererView {
        if case .sampleBuffer = renderMode {
            logger.log("Using AVSampleBufferDisplayLayer for VideoView's Renderer", type: VideoView.self)
            return SampleBufferVideoRenderer()
        } else {
            logger.log("Using RTCMTLVideoView for VideoView's Renderer", type: VideoView.self)
            let result = LKRTCMTLVideoView()

            #if os(iOS)
                result.contentMode = .scaleAspectFit
                result.videoContentMode = .scaleAspectFit
            #endif

            // extra checks for MTKView
            if let mtkView = result.findMTKView() {
                #if os(iOS)
                    mtkView.contentMode = .scaleAspectFit
                #elseif os(macOS)
                    mtkView.layerContentsPlacement = .scaleProportionallyToFit
                #endif
                // ensure it's capable of rendering 60fps
                // https://developer.apple.com/documentation/metalkit/mtkview/1536027-preferredframespersecond
                logger.log("preferredFramesPerSecond = 60", type: VideoView.self)
                mtkView.preferredFramesPerSecond = 60
            }

            return result
        }
    }
}

// MARK: - Access MTKView

extension NativeViewType {
    func findMTKView() -> MTKView? {
        subviews.compactMap { $0 as? MTKView }.first
    }
}

#if os(macOS)
    extension NSView {
        //
        // Converted to Swift + NSView from:
        // http://stackoverflow.com/a/10700737
        //
        func set(anchorPoint: CGPoint) {
            if let layer {
                var newPoint = CGPoint(x: bounds.size.width * anchorPoint.x,
                                       y: bounds.size.height * anchorPoint.y)
                var oldPoint = CGPoint(x: bounds.size.width * layer.anchorPoint.x,
                                       y: bounds.size.height * layer.anchorPoint.y)

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

extension LKRTCMTLVideoView: Mirrorable {
    func set(mirrored: Bool) {
        if mirrored {
            #if os(macOS)
                // This is required for macOS
                wantsLayer = true
                set(anchorPoint: CGPoint(x: 0.5, y: 0.5))
                layer!.sublayerTransform = VideoView.mirrorTransform
            #elseif os(iOS)
                layer.transform = VideoView.mirrorTransform
            #endif
        } else {
            #if os(macOS)
                layer?.sublayerTransform = CATransform3DIdentity
            #elseif os(iOS)
                layer.transform = CATransform3DIdentity
            #endif
        }
    }
}
