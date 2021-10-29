import Foundation
import WebRTC

#if !os(macOS)
import UIKit
#else
import AppKit
#endif

public class VideoView: NativeView {

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
        if let rendererView = rendererView as? NativeViewType {
            addSubview(rendererView)
        }
        shouldLayout()
    }

    override func shouldLayout() {
        super.shouldLayout()
        if let rendererView = rendererView as? NativeViewType {
            rendererView.frame = self.bounds
        }
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
//        // let orientation = UIDevice.current.orientation
//        self.size = size
//
////        UIView.animate(withDuration: 0.4) {
//            let defaultAspectRatio = CGSize(width: 4, height: 3)
//            let aspectRatio = size == .zero ? defaultAspectRatio : size
//            let videoFrame = AVMakeRect(aspectRatio: aspectRatio, insideRect: self.bounds)
//
//            let rendererView = self.renderer as! NativeView
//            rendererView.widthAnchor.constraint(equalToConstant: videoFrame.width).isActive = true
//            rendererView.heightAnchor.constraint(equalToConstant: videoFrame.height).isActive = true
//
//#if !os(macOS)
//        self.layoutIfNeeded()
//#else
//        self.layoutSubtreeIfNeeded()
//#endif
//
    }
}
