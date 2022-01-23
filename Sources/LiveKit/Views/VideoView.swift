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

    override init(frame: CGRect) {
        self.viewSize = frame.size
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public private(set) lazy var rendererView: RTCVideoRenderer = {
        VideoView.createNativeRendererView(delegate: self)
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

    private static func createNativeRendererView(delegate: RTCVideoViewDelegate) -> RTCVideoRenderer {

        DispatchQueue.webRTC.sync {
            let view: RTCVideoRenderer
            #if os(iOS)
            // iOS --------------------
            if isMetalAvailable() {
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
            if isMetalAvailable() {
                logger.log("Using RTCMTLNSVideoView for VideoView's Renderer", type: VideoView.self)
                let mtlView = RTCMTLNSVideoView()
                mtlView.delegate = delegate
                view = mtlView
            } else {
                logger.log("Using RTCNSGLVideoView for VideoView's Renderer", type: VideoView.self)
                let glView = RTCNSGLVideoView()
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
            log("Size is 1x1, ignoring...", .warning)
            return
        }

        DispatchQueue.main.async {
            self.dimensions = Dimensions(width: width,
                                         height: height)
        }
    }
}
