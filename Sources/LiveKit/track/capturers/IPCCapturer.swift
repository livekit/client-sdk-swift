import Foundation
import WebRTC
import Promises

/// Experimental capturer that uses inter-process-communication to receive
/// video buffers
class IPCCapturer: VideoCapturer {

    private let capturer = RTCVideoCapturer()
    private let ipcServer = IPCServer()
    private let ipcName: String

    init(delegate: RTCVideoCapturerDelegate, ipcName: String) {
        self.ipcName = ipcName
        super.init(delegate: delegate)
        
        ipcServer.onReceivedData = { _, messageId, data in
            
            guard let message = try? IPCMessage(serializedData: data) else {
                logger.warning("Failed to decode ipc message")
                return
            }

            if case let .buffer(bufferMessage) = message.type,
               case let .video(videoMessage) = bufferMessage.type {

                // restore pixel buffer from data
                let pixelBuffer = CVPixelBuffer.from(bufferMessage.buffer,
                                                     width: Int(videoMessage.width),
                                                     height: Int(videoMessage.height),
                                                     pixelFormat: videoMessage.format)

                // TODO: handle rotation
                
                delegate.capturer(self.capturer,
                                   didCapture: pixelBuffer,
                                   timeStampNs: bufferMessage.timestampNs,
                                   rotation: ._0)
            }
        }
    }
    
    override func startCapture() -> Promise<Void> {
        super.startCapture().then {
            // start listening for ipc messages
            self.ipcServer.listen(self.ipcName)
        }
    }
    
    override func stopCapture() -> Promise<Void> {
        super.stopCapture().then {
            // stop listening for ipc messages
            self.ipcServer.close()
        }
    }
}

extension LocalVideoTrack {

    public static func createIPCTrack(name: String = Track.screenShareName,
                                      ipcName: String,
                                      source: VideoTrack.Source = .screenShareVideo) -> LocalVideoTrack {
        let videoSource = Engine.factory.videoSource()
        let capturer = IPCCapturer(delegate: videoSource, ipcName: ipcName)
        return LocalVideoTrack(
            capturer: capturer,
            videoSource: videoSource,
            name: name,
            source: source
        )
    }
}
