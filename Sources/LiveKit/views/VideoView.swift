import Foundation
import WebRTC
import CoreMedia

#if !os(macOS)
import UIKit
#else
import AppKit
#endif

public class VideoView: NativeView {

    public private(set) lazy var rendererView: RTCVideoRenderer = {
        VideoView.createNativeRendererView(delegate: self)
    }()

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

        #if arch(arm64)

            #if !os(macOS)
            // iOS
            let view = RTCMTLVideoView()
            view.videoContentMode = .scaleAspectFill
            view.delegate = delegate
            #else
            // macOS
            let view = RTCMTLNSVideoView()
            view.delegate = delegate
            #endif

        #else
            // x64
            let view = RTCEAGLVideoView()
            view.contentMode = .scaleAspectFill
            view.delegate = delegate
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
