import Foundation
import WebRTC
import CoreMedia
import UIKit

public class VideoView: UIView {
    var size: CGSize = .zero
    public private(set) var renderer: RTCVideoRenderer

    required init?(coder decoder: NSCoder) {
        #if arch(arm64)
            let view = RTCMTLVideoView()
            view.videoContentMode = .scaleAspectFill
            renderer = view
        #else
            let view = RTCEAGLVideoView()
            renderer = view
        #endif
        super.init(coder: decoder)
    }

    override public init(frame: CGRect) {
        #if arch(arm64)
            let view = RTCMTLVideoView(frame: frame)
            view.videoContentMode = .scaleAspectFill
            renderer = view
        #else
            let view = RTCEAGLVideoView(frame: frame)
            renderer = view
        #endif

        super.init(frame: frame)
        backgroundColor = .black
        view.delegate = self
        let rendererView = renderer as! UIView
        rendererView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rendererView)

        NSLayoutConstraint.activate([
            rendererView.centerXAnchor.constraint(equalTo: centerXAnchor),
            rendererView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

extension VideoView: RTCVideoViewDelegate {
    public func videoView(_: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        // let orientation = UIDevice.current.orientation
        self.size = size

        UIView.animate(withDuration: 0.4) {
            let defaultAspectRatio = CGSize(width: 4, height: 3)
            let aspectRatio = size == .zero ? defaultAspectRatio : size
            let videoFrame = AVMakeRect(aspectRatio: aspectRatio, insideRect: self.bounds)

            let rendererView = self.renderer as! UIView
            rendererView.widthAnchor.constraint(equalToConstant: videoFrame.width).isActive = true
            rendererView.heightAnchor.constraint(equalToConstant: videoFrame.height).isActive = true

            self.layoutIfNeeded()
        }
    }
}
