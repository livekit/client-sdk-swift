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
    public var layoutMode: LayoutMode {
        get { _state.layoutMode }
        set { _state.mutate { $0.layoutMode = newValue } }
    }

    /// Flips the video horizontally, useful for local VideoViews.
    public var mirrorMode: MirrorMode {
        get { _state.mirrorMode }
        set { _state.mutate { $0.mirrorMode = newValue } }
    }

    /// Calls addRenderer and/or removeRenderer internally for convenience.
    public weak var track: VideoTrack? {
        get { _state.track }
        set {
            _state.mutate {
                let trackDidUpdate = !($0.track?.isEqual(newValue) ?? false)
                if trackDidUpdate {
                    $0.renderState = []
                }
                $0.track = newValue
            }
        }
    }

    public var isEnabled: Bool {
        get { _state.isEnabled }
        set { _state.mutate { $0.isEnabled = newValue } }
    }

    public override var isHidden: Bool {
        get { _state.isHidden }
        set {
            _state.mutate { $0.isHidden = newValue }
            DispatchQueue.mainSafeAsync { super.isHidden = newValue }
        }
    }

    public var debugMode: Bool {
        get { _state.debugMode }
        set { _state.mutate { $0.debugMode = newValue } }
    }

    private var nativeRenderer: NativeRendererView?

    private var _debugTextView: TextView?

    // MARK: - Internal

    internal struct State {

        weak var track: VideoTrack?
        var isEnabled: Bool = true
        var isHidden: Bool = false

        // layout related
        var viewSize: CGSize
        var rendererSize: CGSize?
        // var needsLayout: Bool = false
        var didLayout: Bool = false
        var layoutMode: LayoutMode = .fill

        var mirrorMode: MirrorMode = .auto
        var renderState = RenderState()

        var debugMode: Bool = false
    }

    internal var _state: StateSync<State>

    public override init(frame: CGRect = .zero) {

        // should always be on main thread
        assert(Thread.current.isMainThread, "must be created on the main thread")

        // initial state
        _state = StateSync(State(viewSize: frame.size))

        super.init(frame: frame)

        #if os(iOS)
        clipsToBounds = true
        #endif

        // trigger events when state mutates
        _state.onMutate = { [weak self] state, oldState in

            guard let self = self else { return }

            var needsLayout = state.debugMode != oldState.debugMode ||
                state.layoutMode != oldState.layoutMode ||
                state.mirrorMode != oldState.mirrorMode

            let canRenderDidUpdate = state.canRender != oldState.canRender
            // track was swapped
            let trackDidUpdate = !(oldState.track?.isEqual(state.track) ?? false)

            if trackDidUpdate || canRenderDidUpdate {

                needsLayout = true

                DispatchQueue.main.async { [weak self] in

                    // clean up old track
                    if let track = oldState.track {

                        guard let self = self else { return }

                        track.remove(videoView: self)

                        if let nr = self.nativeRenderer {
                            self.log("removing nativeRenderer")
                            nr.removeFromSuperview()
                            self.nativeRenderer = nil
                        }

                        // CapturerDelegate
                        if let localTrack = track as? LocalVideoTrack {
                            localTrack.capturer.remove(delegate: self)
                        }

                        // notify detach
                        track.notify { [weak self, weak track] (delegate) -> Void in
                            guard let self = self, let track = track else { return }
                            delegate.track(track, didDetach: self)
                        }
                    }

                    // set new track
                    if let track = state.track, state.canRender {

                        guard let self = self else { return }

                        // re-create renderer on main thread
                        let nr = self.reCreateNativeRenderer()

                        track.add(videoView: self)

                        if let frame = track._state.videoFrame {
                            self.log("rendering cached frame tack: \(track._state.sid ?? "nil")")
                            nr.renderFrame(frame)
                            self.setNeedsLayout()
                        }

                        // CapturerDelegate
                        if let localTrack = track as? LocalVideoTrack {
                            localTrack.capturer.add(delegate: self)
                        }

                        // notify attach
                        track.notify { [weak self, weak track] (delegate) -> Void in
                            guard let self = self, let track = track else { return }
                            delegate.track(track, didAttach: self)
                        }
                    }
                }
            }

            // renderState updated
            if state.renderState != oldState.renderState, let track = state.track {
                track.notify { $0.track(track, videoView: self, didUpdate: state.renderState) }
            }

            // viewSize updated
            if state.viewSize != oldState.viewSize, let track = state.track {
                track.notify { $0.track(track, videoView: self, didUpdate: state.viewSize) }
            }

            // toggle MTKView's isPaused property
            // https://developer.apple.com/documentation/metalkit/mtkview/1535973-ispaused
            // https://developer.apple.com/forums/thread/105252
            // nativeRenderer.asMetalView?.isPaused = !shouldAttach

            if needsLayout {
                DispatchQueue.mainSafeAsync {
                    self.setNeedsLayout()
                }
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        log()
    }

    override func performLayout() {
        super.performLayout()

        // should always be on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        defer {
            let size = frame.size

            if _state.viewSize != size || !_state.didLayout {
                // mutate if required
                _state.mutate {
                    $0.viewSize = size
                    $0.didLayout = true
                }
            }
        }

        if _state.debugMode {
            let t = _state.track?.sid ?? "nil"
            let d = _state.track?.dimensions ?? .zero
            let c = _state.renderState.contains(.didRenderFirstFrame) ? "true" : "false"
            let videoViewCount = _state.track?.videoViews.count ?? 0
            let _didLayout = _state.didLayout
            let r = ensureDebugTextView()
            r.text = "VideoView#\(hashValue)\n" + "\(t)\n" + "\(d.width)x\(d.height)\n" + "isEnabled: \(isEnabled)\n" + "didRenderFirstFrame: \(c)\n" + "videoViewCount: \(videoViewCount)\n" + "didLayout: \(_didLayout)"
            r.frame = bounds
        }

        guard let track = _state.track else {
            log("track is nil, cannot layout without track")
            return
        }

        // dimensions are required to continue computation
        guard let dimensions = track._state.dimensions else {
            log("dimensions are nil, cannot layout without dimensions, track: \(track)")
            return
        }

        var size = frame.size
        let wDim = CGFloat(dimensions.width)
        let hDim = CGFloat(dimensions.height)
        let wRatio = size.width / wDim
        let hRatio = size.height / hDim

        if .fill == _state.layoutMode ? hRatio > wRatio : hRatio < wRatio {
            size.width = size.height / hDim * wDim
        } else if .fill == _state.layoutMode ? wRatio > hRatio : wRatio < hRatio {
            size.height = size.width / wDim * hDim
        }

        let rendererFrame = CGRect(x: -((size.width - frame.size.width) / 2),
                                   y: -((size.height - frame.size.height) / 2),
                                   width: size.width,
                                   height: size.height)

        nativeRenderer?.frame = rendererFrame

        if _state.rendererSize != rendererFrame.size {
            // mutate if required
            _state.mutate { $0.rendererSize = rendererFrame.size }
        }

        // nativeRenderer.wantsLayer = true
        // nativeRenderer.layer!.borderColor = NSColor.red.cgColor
        // nativeRenderer.layer!.borderWidth = 3

        if let nr = nativeRenderer {

            if shouldMirror() {
                #if os(macOS)
                // this is required for macOS
                nr.wantsLayer = true
                nr.set(anchorPoint: CGPoint(x: 0.5, y: 0.5))
                nr.layer!.sublayerTransform = VideoView.mirrorTransform
                #elseif os(iOS)
                nr.layer.transform = VideoView.mirrorTransform
                #endif
            } else {
                #if os(macOS)
                nr.layer?.sublayerTransform = CATransform3DIdentity
                #elseif os(iOS)
                nr.layer.transform = CATransform3DIdentity
                #endif
            }
        }
    }
}

internal extension VideoView.State {

    var canRender: Bool {
        track != nil && isEnabled && !isHidden
    }
}

// MARK: - Private

private extension VideoView {

    private func ensureDebugTextView() -> TextView {
        if let d = _debugTextView { return d }
        let r = TextView()
        addSubview(r)
        _debugTextView = r
        return r
    }

    func reCreateNativeRenderer() -> NativeRendererView {
        // should always be on main thread
        assert(Thread.current.isMainThread, "must be called on main thread")

        let newView = VideoView.createNativeRendererView()
        addSubview(newView)

        let oldView = nativeRenderer
        nativeRenderer = newView

        if let oldView = oldView {
            oldView.removeFromSuperview()
        }

        if let view = _debugTextView {
            #if os(iOS)
            bringSubviewToFront(view)
            #elseif os(macOS)
            addSubview(view)
            #endif
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

extension VideoView: RTCVideoRenderer {

    public func setSize(_ size: CGSize) {
        guard let nr = nativeRenderer else { return }
        nr.setSize(size)
    }

    public func renderFrame(_ frame: RTCVideoFrame?) {

        // prevent any extra rendering if already !isEnabled etc.
        guard _state.canRender, let nr = nativeRenderer else {
            log("canRender is false, skipping render...")
            return
        }

        var _needsLayout = false
        defer {
            if _needsLayout {
                DispatchQueue.mainSafeAsync {
                    self.setNeedsLayout()
                }
            }
        }

        if let frame = frame {

            let dimensions = Dimensions(width: frame.width,
                                        height: frame.height)
                .apply(rotation: frame.rotation)

            guard dimensions.isRenderSafe else {
                log("skipping render for dimension \(dimensions)", .warning)
                // renderState.insert(.didSkipUnsafeFrame)
                return
            }

            if track?.set(dimensions: dimensions) == true {
                _needsLayout = true
            }

        } else {
            if track?.set(dimensions: nil) == true {
                _needsLayout = true
            }
        }

        nr.renderFrame(frame)

        // cache last rendered frame
        track?.set(videoFrame: frame)

        if !_state.renderState.contains(.didRenderFirstFrame) {
            _state.mutate { $0.renderState.insert(.didRenderFirstFrame) }
            self.log("Did render first frame")
            _needsLayout = true
        }
    }
}

// MARK: - VideoCapturerDelegate

extension VideoView: VideoCapturerDelegate {

    public func capturer(_ capturer: VideoCapturer, didUpdate state: VideoCapturer.CapturerState) {
        if case .started = state {
            DispatchQueue.mainSafeAsync {
                self.setNeedsLayout()
            }
        }
    }
}

// MARK: - Internal

internal extension VideoView {

    var isVisible: Bool {
        _state.didLayout && !_state.isHidden && _state.isEnabled
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

    internal static func createNativeRendererView() -> NativeRendererView {
        let result: NativeRendererView
        #if targetEnvironment(simulator)
        // iOS Simulator ---------------
        logger.log("Using RTCEAGLVideoView for VideoView's Renderer", type: VideoView.self)
        let eaglView = RTCEAGLVideoView()
        eaglView.contentMode = .scaleAspectFit
        result = eaglView
        #else
        #if os(iOS)
        // iOS --------------------
        logger.log("Using RTCMTLVideoView for VideoView's Renderer", type: VideoView.self)
        let mtlView = RTCMTLVideoView()
        // use .fit here to match macOS behavior and
        // manually calculate .fill if necessary
        mtlView.contentMode = .scaleAspectFit
        mtlView.videoContentMode = .scaleAspectFit
        result = mtlView
        #else
        // macOS --------------------
        logger.log("Using RTCMTLNSVideoView for VideoView's Renderer", type: VideoView.self)
        result = RTCMTLNSVideoView()
        #endif
        #endif

        // extra checks for MTKView
        if let metal = result.asMetalView {
            #if os(iOS)
            metal.contentMode = .scaleAspectFit
            #elseif os(macOS)
            metal.layerContentsPlacement = .scaleProportionallyToFit
            #endif
        }

        return result
    }
}

// MARK: - Access MTKView

internal extension NativeViewType {

    var asMetalView: MTKView? {
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
