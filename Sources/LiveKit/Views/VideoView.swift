import Foundation
import WebRTC

#if os(iOS)
typealias NativeRect = CGRect
import UIKit
#else
import AppKit
typealias NativeRect = NSRect
#endif

/// A ``NativeViewType`` that conforms to ``RTCVideoRenderer``.
public typealias NativeRendererView = NativeViewType & RTCVideoRenderer

public class VideoView: NativeView, Loggable {

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

    public enum Mode: String, Codable, CaseIterable {
        case fit
        case fill
    }

    public internal(set) var renderState = RenderState() {
        didSet {
            guard oldValue != renderState else { return }
            track?.notify { $0.track(self.track!, videoView: self, didUpdate: self.renderState) }
        }
    }

    /// Layout ``Mode`` of the ``VideoView``.
    public var mode: Mode = .fit {
        didSet {
            guard oldValue != mode else { return }
            log("mode: \(String(describing: oldValue)) -> \(String(describing: self.mode))")
            DispatchQueue.main.async { self.markNeedsLayout() }
        }
    }

    public var mirrored: Bool = false {
        didSet {
            guard oldValue != mirrored else { return }
            log("mirrored: \(String(describing: oldValue)) -> \(String(describing: self.mirrored))")
            DispatchQueue.main.async { self.markNeedsLayout() }
        }
    }

    /// OpenGL is deprecated and the SDK prefers to use Metal by default.
    /// Setting false when creating ``VideoView`` will force to use OpenGL.
    public var preferMetal: Bool {
        didSet {
            guard oldValue != preferMetal else { return }
            DispatchQueue.main.async { self.reCreateRenderer() }
        }
    }

    /// Size of the actual video, this will change when the publisher
    /// changes dimensions of the video such as rotating etc.
    public private(set) var dimensions: Dimensions?

    private func set(dimensions newValue: Dimensions?) {
        guard self.dimensions != newValue else { return }
        log("\(String(describing: self.dimensions)) -> \(String(describing: newValue))")
        self.dimensions = newValue
        // force layout
        DispatchQueue.main.async { self.markNeedsLayout() }
        // notify dimensions update
        if let track = track, let dimensions = newValue {
            track.notify { [weak track] (delegate) -> Void in
                guard let track = track else { return }
                delegate.track(track, videoView: self, didUpdate: dimensions)
            }
        }
    }

    /// Size of this view (used to notify delegates)
    /// usually should be equal to `frame.size`
    public internal(set) var viewSize: CGSize {
        didSet {
            guard oldValue != viewSize else { return }
            // notify viewSize update
            track?.notify { $0.track(self.track!, videoView: self, didUpdate: self.viewSize) }
        }
    }

    /// Calls addRenderer and/or removeRenderer internally for convenience.
    public var track: VideoTrack? {
        didSet {
            if let oldValue = oldValue {
                oldValue.removeRenderer(self)
                oldValue.notify { $0.track(oldValue, didDetach: self) }
            }
            track?.addRenderer(self)
            track?.notify { [weak track] (delegate) -> Void in
                guard let track = track else { return }
                delegate.track(track, didAttach: self)
            }
            // if nil is set, clear out the renderer
            if track == nil { renderFrame(nil) }
        }
    }

    private var renderer: NativeRendererView

    init(frame: CGRect = .zero, preferMetal: Bool = true) {
        self.viewSize = frame.size
        self.preferMetal = preferMetal
        renderer = VideoView.createNativeRendererView(preferMetal: preferMetal)
        // renderer.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: frame)
        log("layout: Created")
        // translatesAutoresizingMaskIntoConstraints = false
        addSubview(renderer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static let mirrorTransform = CATransform3DMakeScale(-1.0, 1.0, 1.0)

    override func shouldLayout() {
        super.shouldLayout()

        log("layout: Should layout, dim: \(String(describing: dimensions))")

        defer { self.viewSize = self.frame.size }

        // dimensions are required to continue computation
        guard let dimensions = dimensions else {
            log("layout: Skipping layout since dimensions are unknown", .warning)
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

        renderer.frame = CGRect(x: -((size.width - frame.size.width) / 2),
                                y: -((size.height - frame.size.height) / 2),
                                width: size.width,
                                height: size.height)

        if mirrored {
            #if os(macOS)
            // this is required for macOS
            renderer.set(anchorPoint: CGPoint(x: 0.5, y: 0.5))
            renderer.wantsLayer = true
            renderer.layer!.sublayerTransform = VideoView.mirrorTransform
            #elseif os(iOS)
            renderer.layer.transform = VideoView.mirrorTransform
            #endif
        } else {
            #if os(macOS)
            renderer.layer?.sublayerTransform = CATransform3DIdentity
            #elseif os(iOS)
            renderer.layer.transform = CATransform3DIdentity
            #endif
        }
    }

    private func reCreateRenderer() {
        // Save current track if exists
        let currentTrack = self.track
        // Remove track (notify delegates)
        self.track = nil
        // Remove the renderer view
        renderer.removeFromSuperview()
        // Clear the renderState
        renderState = []
        // Re-create renderer view
        renderer = VideoView.createNativeRendererView(preferMetal: preferMetal)
        addSubview(renderer)
        // Set previous track to new renderer view
        self.track = currentTrack
    }
}

// MARK: - RTCVideoRenderer

extension VideoView: RTCVideoRenderer {

    public func setSize(_ size: CGSize) {
        renderer.setSize(size)
    }

    public func renderFrame(_ frame: RTCVideoFrame?) {

        if let frame = frame {

            let dimensions = Dimensions(width: frame.width,
                                        height: frame.height)

            // check if dimensions are safe to pass to renderer
            guard dimensions.isRenderSafe else {
                log("Skipping render for dimension \(dimensions)", .warning)
                renderState.insert(.didSkipUnsafeFrame)
                return
            }

            self.set(dimensions: dimensions)

            // layout after first frame has been rendered
            if !renderState.contains(.didRenderFirstFrame) {
                renderState.insert(.didRenderFirstFrame)
                log("layout: did render first frame")
                DispatchQueue.main.async { self.markNeedsLayout() }
            }
        }

        renderer.renderFrame(frame)
        renderState.remove(.didSkipUnsafeFrame)
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

            return view
        }
    }
}

#if os(macOS)
//
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
