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

    public enum Mode: String, Codable, CaseIterable {
        case fit
        case fill
    }

    /// Layout ``Mode`` of the ``VideoView``.
    public var mode: Mode = .fill {
        didSet {
            guard oldValue != mode else { return }
            markNeedsLayout()
        }
    }

    public var mirrored: Bool = false {
        didSet {
            guard oldValue != mirrored else { return }
            update(mirrored: mirrored)
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

    /// Size of the actual video, this will change when the publisher
    /// changes dimensions of the video such as rotating etc.
    public internal(set) var dimensions: Dimensions? {
        didSet {
            guard oldValue != dimensions else { return }
            log("\(String(describing: oldValue)) -> \(String(describing: dimensions))")
            // force layout
            markNeedsLayout()
            // notify dimensions update
            guard let dimensions = dimensions else { return }
            track?.notify { [weak track] (delegate) -> Void in
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
        }
    }

    internal var nativeRenderer: NativeRendererView
    internal var nativeRendererDidRenderFirstFrame: Bool = false

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

        defer {
            DispatchQueue.main.async {
                self.viewSize = self.frame.size
            }
        }

        // dimensions are required to continue computation
        guard let dimensions = dimensions else {
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
        nativeRenderer.frame = CGRect(x: -((size.width - frame.size.width) / 2),
                                      y: -((size.height - frame.size.height) / 2),
                                      width: size.width,
                                      height: size.height)
    }

    private static let mirrorTransform = CGAffineTransform(scaleX: -1.0, y: 1.0)

    private func update(mirrored: Bool) {
        #if os(iOS)
        let layer = self.layer
        #elseif os(macOS)
        guard let layer = self.layer else { return }
        #endif
        layer.setAffineTransform(mirrored ? VideoView.mirrorTransform : .identity)
    }

    private func reCreateNativeRenderer() {
        // Save current track if exists
        let currentTrack = self.track
        // Remove track (notify delegates)
        self.track = nil
        // Remove the renderer view
        nativeRenderer.removeFromSuperview()
        nativeRendererDidRenderFirstFrame = false
        // Re-create renderer view
        nativeRenderer = VideoView.createNativeRendererView(preferMetal: preferMetal)
        addSubview(nativeRenderer)
        // Set previous track to new renderer view
        self.track = currentTrack

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

            // check if dimensions are safe to pass to renderer
            guard dimensions.isRenderSafe else {
                log("Skipping render for dimension \(dimensions)", .warning)
                return
            }

            DispatchQueue.main.async { self.dimensions = dimensions }
        }

        nativeRenderer.renderFrame(frame)

        // layout after first frame has been rendered
        if !nativeRendererDidRenderFirstFrame {
            nativeRendererDidRenderFirstFrame = true
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

            return view
        }
    }
}
