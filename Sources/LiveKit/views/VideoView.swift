import Foundation
import WebRTC
import CoreMedia

#if !os(macOS)
import UIKit
public typealias NativeView = UIView
#else
// macOS
public typealias NativeView = NSView
#endif

public class VideoView: NativeView {
    var size: CGSize = .zero

    public private(set) lazy var renderer: RTCVideoRenderer = {
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
        view.delegate = self
        #endif
        return view
    }()

    required init?(coder decoder: NSCoder) {
//        renderer = createRTCVideoView(delegate: self)
        super.init(coder: decoder)
    }

    override public init(frame: CGRect) {

        super.init(frame: frame)

//        backgroundColor = .black
//        view.delegate = self
        let rendererView = self.renderer as! NativeView
        rendererView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rendererView)

        NSLayoutConstraint.activate([
            rendererView.centerXAnchor.constraint(equalTo: centerXAnchor),
            rendererView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

extension VideoView: RTCVideoViewDelegate {

    public func videoView(_: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        // let orientation = UIDevice.current.orientation
        self.size = size

//        UIView.animate(withDuration: 0.4) {
            let defaultAspectRatio = CGSize(width: 4, height: 3)
            let aspectRatio = size == .zero ? defaultAspectRatio : size
            let videoFrame = AVMakeRect(aspectRatio: aspectRatio, insideRect: self.bounds)

            let rendererView = self.renderer as! NativeView
            rendererView.widthAnchor.constraint(equalToConstant: videoFrame.width).isActive = true
            rendererView.heightAnchor.constraint(equalToConstant: videoFrame.height).isActive = true

#if !os(macOS)
        self.layoutIfNeeded()
#else
        self.layoutSubtreeIfNeeded()
#endif

    }
}
