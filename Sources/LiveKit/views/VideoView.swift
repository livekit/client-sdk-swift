import Foundation
import WebRTC
import CoreMedia

#if !os(macOS)
import UIKit
import SwiftUI
public typealias NativeViewType = UIView
#else
// macOS
public typealias NativeViewType = NSView
#endif

public class VideoView: NativeViewType {

    public private(set) lazy var rendererView: RTCVideoRenderer = {
        #if arch(arm64)

        #if !os(macOS)
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.delegate = self
        #else
        // macOS
        let view = RTCMTLNSVideoView()
        view.delegate = self
        #endif

        #else
        // intel
        let view = RTCEAGLVideoView()
        view.contentMode = .scaleAspectFill
        view.delegate = self
        #endif
        return view
    }()

    required init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)

#if !os(macOS)
        layer.backgroundColor = UIColor.black.cgColor
#else
        layer?.backgroundColor = NSColor.black.cgColor
#endif

        if let rendererView = rendererView as? NativeViewType {
            addSubview(rendererView)
        }
        layoutRenderView()
    }

    private func layoutRenderView() {
        if let rendererView = rendererView as? NativeViewType {
            rendererView.frame = self.bounds
        }
    }

#if !os(macOS)
    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutRenderView()
    }
#else
    public override func layout() {
        super.layout()
        layoutRenderView()
    }
#endif
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
