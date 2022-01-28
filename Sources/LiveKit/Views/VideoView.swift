import Foundation
import WebRTC

#if os(iOS)
typealias NativeRect = CGRect
import UIKit
#else
import AppKit
typealias NativeRect = NSRect
#endif

public class VideoView: NativeView, Loggable {

    public enum Mode {
        case fit
        case fill
    }

    public var mode: Mode = .fill {
        didSet {
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
    public let preferMetal: Bool

    /// Size of the actual video, this will change when the publisher
    /// changes dimensions of the video such as rotating etc.
    public private(set) var dimensions: Dimensions? {
        didSet {
            guard oldValue != dimensions else { return }
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
    public private(set) var viewSize: CGSize {
        didSet {
            guard oldValue != viewSize else { return }
            // notify viewSize update
            track?.notify { $0.track(self.track!, videoView: self, didUpdate: self.viewSize) }
        }
    }

    init(frame: CGRect = .zero, preferMetal: Bool = true) {
        self.viewSize = frame.size
        self.preferMetal = preferMetal
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public private(set) lazy var rendererView: RTCVideoRenderer = {
        VideoView.createNativeRendererView(delegate: self,
                                           preferMetal: preferMetal)
    }()

    /// Calls addRenderer and/or removeRenderer internally for convenience.
    public var track: VideoTrack? {
        didSet {
            if let oldValue = oldValue {
                oldValue.removeRenderer(rendererView)
                oldValue.notify { $0.track(oldValue, didDetach: self) }
            }
            track?.addRenderer(rendererView)
            track?.notify { [weak track] (delegate) -> Void in
                guard let track = track else { return }
                delegate.track(track, didAttach: self)
            }
        }
    }

    override func shouldPrepare() {
        super.shouldPrepare()
        guard let rendererView = rendererView as? NativeViewType else { return }
        rendererView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(rendererView)
        shouldLayout()
    }

    override func shouldLayout() {
        super.shouldLayout()
        self.viewSize = frame.size

        guard let rendererView = rendererView as? NativeViewType else { return }

        guard let dimensions = dimensions else {
            rendererView.isHidden = true
            return
        }

        if case .fill = mode {
            // manual calculation for .fill

            var size = viewSize
            let widthRatio = size.width / CGFloat(dimensions.width)
            let heightRatio = size.height / CGFloat(dimensions.height)

            if heightRatio > widthRatio {
                size.width = size.height / CGFloat(dimensions.height) * CGFloat(dimensions.width)
            } else if widthRatio > heightRatio {
                size.height = size.width / CGFloat(dimensions.width) * CGFloat(dimensions.height)
            }

            // center layout
            rendererView.frame = CGRect(x: -((size.width - viewSize.width) / 2),
                                        y: -((size.height - viewSize.height) / 2),
                                        width: size.width,
                                        height: size.height)

        } else {
            //
            rendererView.frame = bounds
        }

        rendererView.isHidden = false
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

    public static func isMetalAvailable() -> Bool {
        #if os(iOS)
        MTLCreateSystemDefaultDevice() != nil
        #elseif os(macOS)
        // same method used with WebRTC
        MTLCopyAllDevices().count > 0
        #endif
    }

    private static func createNativeRendererView(delegate: RTCVideoViewDelegate,
                                                 preferMetal: Bool) -> RTCVideoRenderer {

        DispatchQueue.webRTC.sync {
            let view: RTCVideoRenderer
            #if os(iOS)
            // iOS --------------------
            if preferMetal && isMetalAvailable() {
                logger.log("Using RTCMTLVideoView for VideoView's Renderer", type: VideoView.self)
                let mtlView = RTCMTLVideoView()
                // use .fit here to match macOS behavior and
                // manually calculate .fill if necessary
                mtlView.contentMode = .scaleAspectFit
                mtlView.videoContentMode = .scaleAspectFit
                mtlView.delegate = delegate
                view = mtlView
            } else {
                logger.log("Using RTCEAGLVideoView for VideoView's Renderer", type: VideoView.self)
                let glView = RTCEAGLVideoView()
                glView.contentMode = .scaleAspectFit
                glView.delegate = delegate
                view = glView
            }
            #else
            // macOS --------------------
            if preferMetal && isMetalAvailable() {
                logger.log("Using RTCMTLNSVideoView for VideoView's Renderer", type: VideoView.self)
                let mtlView = RTCMTLNSVideoView()
                mtlView.delegate = delegate
                view = mtlView
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
                let glView = RTCNSGLVideoView(frame: .zero, pixelFormat: pixelFormat)!
                glView.delegate = delegate
                view = glView
            }
            #endif

            return view
        }
    }
}

extension VideoView: RTCVideoViewDelegate {

    public func videoView(_: RTCVideoRenderer, didChangeVideoSize size: CGSize) {

        log("size:\(size)")

        guard let width = Int32(exactly: size.width),
              let height = Int32(exactly: size.height) else {
            // CGSize is used by WebRTC but this should always be an integer
            log("Size width/height is not an integer", .warning)
            return
        }

        guard width > 1, height > 1 else {
            // Handle known issue where the delegate (rarely) reports dimensions of 1x1
            // which causes [MTLTextureDescriptorInternal validateWithDevice] to crash.
            log("Size is \(width)x\(height), ignoring...", .warning)
            return
        }

        DispatchQueue.main.async {
            self.dimensions = Dimensions(width: width,
                                         height: height)
        }
    }
}
