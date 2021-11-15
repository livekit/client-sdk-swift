import WebRTC

extension RTCVideoCapturerDelegate {

    /// capture a `CVPixelBuffer`
    public func capturer(_ capturer: RTCVideoCapturer,
                         didCapture pixelBuffer: CVPixelBuffer,
                         timeStampNs: UInt64) {

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            // The source only supports NV12 (full-range) buffers.
            return
        }

        //        let width = CVPixelBufferGetWidth(pixelBuffer)
        //        let height = CVPixelBufferGetHeight(pixelBuffer)

        // TODO: improve, support rotation etc.
        //
        //        source.adaptOutputFormat(toWidth: Int32(width/2),
        //                                 height: Int32(height/2),
        //                                 fps: 15)

        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)

        let frame = RTCVideoFrame(buffer: rtcBuffer,
                                  rotation: ._0,
                                  timeStampNs: Int64(timeStampNs))

        self.capturer(capturer, didCapture: frame)
    }

    /// capture a `CMSampleBuffer`
    public func capturer(_ capturer: RTCVideoCapturer,
                         didCapture sampleBuffer: CMSampleBuffer) {

        // check if buffer is ready
        guard CMSampleBufferGetNumSamples(sampleBuffer) == 1,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = UInt64(CMTimeGetSeconds(timeStamp) * Double(NSEC_PER_SEC))

        self.capturer(capturer, didCapture: pixelBuffer, timeStampNs: timeStampNs)
    }
}
