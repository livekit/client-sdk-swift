import Foundation
import WebRTC
import Promises

class BufferCapturer: VideoCapturer {

    func startCapture() -> Promise<Void> {
        // nothing to do for now
        Promise(())
    }

    func stopCapture() -> Promise<Void> {
        // nothing to do for now
        Promise(())
    }

    // shortcut
    func capture(_ sampleBuffer: CMSampleBuffer) {
        delegate?.capturer(self, didCapture: sampleBuffer)
    }
}
