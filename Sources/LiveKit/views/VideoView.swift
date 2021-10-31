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

    enum Mode {
        case fit
        case fill
    }

    var mode: Mode = .fill {
        didSet {
            shouldLayout()
        }
    }

    var videoSize: CGSize

    override init(frame: CGRect) {
        self.videoSize = frame.size
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
            }
            track?.addRenderer(rendererView)
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
        guard let rendererView = rendererView as? NativeViewType else { return }

        let viewSize = bounds.size
        guard videoSize.width != 0.0 || videoSize.height != 0.0 else {
            rendererView.isHidden = true
            return
        }

        if .fill == mode {
            // manual calculation for .fill
            let width, height: CGFloat
            var xDiff: CGFloat = 0.0
            var yDiff: CGFloat = 0.0
            if videoSize.width > videoSize.height {
                let ratio = videoSize.width / videoSize.height
                width = viewSize.height * ratio
                height = viewSize.height
                xDiff = (width - height) / 2
            } else {
                let ratio = videoSize.height / videoSize.width
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
        self.videoSize = size
        shouldLayout()
    }
}
