import Foundation
import WebRTC
import MetalKit

extension Dimensions {

    func toCGSize() -> CGSize {
        CGSize(width: Int(width), height: Int(height))
    }
}

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

    public enum Mode: String, Codable, CaseIterable {
        case fit
        case fill
    }

    /// Layout ``Mode`` of the ``VideoView``.
    public var mode: Mode = .fill {
        didSet {
            guard oldValue != mode else { return }
            DispatchQueue.mainSafeAsync {
                self.markNeedsLayout()
            }
        }
    }

    /// Flips the video horizontally, useful for local VideoViews.
    /// Known Issue: this will not work when os is macOS and ``preferMetal`` is false.
    public var mirrored: Bool = false {
        didSet {
            guard oldValue != mirrored else { return }
            DispatchQueue.mainSafeAsync {
                self.markNeedsLayout()
            }
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
    public var track: VideoTrack? {
        didSet {
            guard !(oldValue?.isEqual(to: track) ?? false) else { return }

            if let oldValue = oldValue {
                oldValue.remove(delegate: self)
                oldValue.notify { $0.track(oldValue, didDetach: self) }
            }
            track?.add(delegate: self)
            track?.notify { [weak track] (delegate) -> Void in
                guard let track = track else { return }
                delegate.track(track, didAttach: self)
            }

            if let track = track {
                // if track knows dimensions, prepare the renderer
                if let dimensions = track.dimensions {
                    DispatchQueue.webRTC.sync {
                        nativeRenderer.setSize(dimensions.toCGSize())
                    }
                }
                // log("rendering last frame")
                // nativeRenderer.renderFrame(lastFrame)
            } else {
                // if nil is set, clear out the renderer
                DispatchQueue.webRTC.sync { nativeRenderer.renderFrame(nil) }
                renderState = []
            }

            DispatchQueue.mainSafeAsync {
                self.markNeedsLayout()
            }
        }
    }

    internal var nativeRenderer: NativeRendererView

    init(frame: CGRect = .zero, preferMetal: Bool = true) {
        self.viewSize = frame.size
        self.preferMetal = preferMetal
        self.nativeRenderer = VideoView.createNativeRendererView(preferMetal: preferMetal)
        super.init(frame: frame)
        addSubview(nativeRenderer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func shouldLayout() {
        super.shouldLayout()

        // this should never happen
        assert(Thread.current.isMainThread, "shouldLayout must be called from main thread")

        defer {
            DispatchQueue.main.async {
                self.viewSize = self.frame.size
            }
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

        if .fill == mode ? hRatio > wRatio : hRatio < wRatio {
            size.width = size.height / hDim * wDim
        } else if .fill == mode ? wRatio > hRatio : wRatio < hRatio {
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

        if mirrored {
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

// MARK: - TrackDelegate

extension VideoView: TrackDelegate {

    public func track(_ track: VideoTrack, didUpdate dimensions: Dimensions?) {

        if let dimensions = dimensions {
            DispatchQueue.webRTC.sync {
                nativeRenderer.setSize(dimensions.toCGSize())
            }
        }

        // re-compute layout when dimensions change
        DispatchQueue.mainSafeAsync {
            self.markNeedsLayout()
        }
    }

    public func track(_ track: VideoTrack, didReceive frame: RTCVideoFrame?) {

        DispatchQueue.webRTC.sync {
            nativeRenderer.renderFrame(frame)
        }

        // layout after first frame has been rendered
        if !renderState.contains(.didRenderFirstFrame) {
            renderState.insert(.didRenderFirstFrame)
            log("Did render first frame")
            DispatchQueue.main.async { self.markNeedsLayout() }
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
        MTLCopyAllDevices().count > 0
        #endif
    }

    internal static func createNativeRendererView(preferMetal: Bool) -> NativeRendererView {

        DispatchQueue.webRTC.sync {
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
                    metal.layerContentsPlacement = .scaleProportionallyToFit
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
