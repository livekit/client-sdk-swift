import Foundation
import WebRTC

#if !os(macOS)
typealias NativeRect = CGRect
import UIKit
#else
import AppKit
typealias NativeRect = NSRect
#endif

public class VideoView: NativeView {

    public enum Mode {
        case fit
        case fill
    }

    public var mode: Mode = .fill {
        didSet {
            markNeedsLayout()
        }
    }

    /// Size of the actual video, this will change when the publisher
    /// changes dimensions of the video such as rotating etc.
    public private(set) var dimensions: Dimensions? {
        didSet {
            guard oldValue != dimensions else { return }
            // force layout
            markNeedsLayout()
            if let dimensions = dimensions {
                track?.notify { $0.track(self.track!, videoView: self, didUpdate: dimensions) }
            }
        }
    }

    /// Size of this view (used to notify delegates)
    internal var viewSize: CGSize {
        didSet {
            guard oldValue != viewSize else { return }
            print("viewSize did update: \(viewSize) notifying: \(String(describing: track))")
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
            track?.notify { $0.track(self.track!, didAttach: self) }
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

        if .fill == mode {
            // manual calculation for .fill
            let width, height: CGFloat
            var xDiff: CGFloat = 0.0
            var yDiff: CGFloat = 0.0
            if dimensions.width > dimensions.height {
                let ratio = CGFloat(dimensions.width) / CGFloat(dimensions.height)
                width = viewSize.height * ratio
                height = viewSize.height
                xDiff = (width - height) / 2
            } else {
                let ratio = CGFloat(dimensions.height) / CGFloat(dimensions.width)
                width = viewSize.width
                height = viewSize.width * ratio
                yDiff = (height - width) / 2
            }

            rendererView.frame = NativeRect(x: -xDiff,
                                            y: -yDiff,
                                            width: width,
                                            height: height)
        } else {
            //
            rendererView.frame = bounds
        }

        rendererView.isHidden = false
    }

    static func createNativeRendererView(delegate: RTCVideoViewDelegate) -> RTCVideoRenderer {

        #if !os(macOS)
        // iOS --------------------

        #if targetEnvironment(simulator)
        print("Using RTCEAGLVideoView for VideoView's Renderer")
        let view = RTCEAGLVideoView()
        view.contentMode = .scaleAspectFit
        view.delegate = delegate
        #else
        print("Using RTCMTLVideoView for VideoView's Renderer")
        let view = RTCMTLVideoView()
        // use .fit here to match macOS behavior and
        // manually calculate .fill if necessary
        view.contentMode = .scaleAspectFit
        view.videoContentMode = .scaleAspectFit
        view.delegate = delegate
        #endif

        #else
        // macOS --------------------
        let view: RTCVideoRenderer
        if RTCMTLNSVideoView.isMetalAvailable() {
            print("Using RTCMTLNSVideoView for VideoView's Renderer")
            let mtlView = RTCMTLNSVideoView()
            mtlView.delegate = delegate
            view = mtlView
        } else {
            print("Using RTCNSGLVideoView for VideoView's Renderer")
            let glView = RTCNSGLVideoView()
            glView.delegate = delegate
            view = glView
        }
        #endif

        return view
    }
}

extension VideoView: RTCVideoViewDelegate {

    public func videoView(_: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        print("VideoView.didChangeVideoSize \(size)")

        guard let width = Int32(exactly: size.width),
              let height = Int32(exactly: size.height) else {
            // CGSize is used by WebRTC but this should always be an integer
            print("Warning: size width/height is not an integer")
            return
        }

        DispatchQueue.main.async {
            self.dimensions = Dimensions(width: width,
                                         height: height)
        }
    }
}
