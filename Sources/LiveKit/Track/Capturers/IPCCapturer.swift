import Foundation
import WebRTC
import Promises

/// Experimental capturer that uses inter-process-communication to receive
/// video buffers
class IPCCapturer: VideoCapturer {

    private let capturer = RTCVideoCapturer()
    private let ipcChannel = IPCChannel()
    private let ipcName: String

    init(delegate: RTCVideoCapturerDelegate, ipcName: String) {
        self.ipcName = ipcName
        super.init(delegate: delegate)

        ipcChannel.onReceivedData = { _, _, _ in

            //            guard let message = try? IPCMessage(serializedData: data) else {
            //                logger.warning("Failed to decode ipc message")
            //                return
            //            }
            //
            //            if case .buffer(let bufferMessage) = message.type,
            //               case .video(let videoMessage) = bufferMessage.type {
            //
            //                // restore pixel buffer from data
            //                let pixelBuffer = CVPixelBuffer.from(bufferMessage.buffer,
            //                                                     width: Int(videoMessage.width),
            //                                                     height: Int(videoMessage.height),
            //                                                     pixelFormat: videoMessage.format)
            //
            //                delegate.capturer(self.capturer,
            //                                  didCapture: pixelBuffer,
            //                                  timeStampNs: bufferMessage.timestampNs,
            //                                  rotation: RTCVideoRotation(rawValue: Int(videoMessage.rotation)) ?? ._0)
            //            }
        }
    }

    override func startCapture() -> Promise<Void> {
        super.startCapture().then {
            // start listening for ipc messages
            self.ipcChannel.open(self.ipcName)
        }
    }

    override func stopCapture() -> Promise<Void> {
        super.stopCapture().then {
            // stop listening for ipc messages
            self.ipcChannel.close()
        }
    }
}

extension LocalVideoTrack {

    public static func createIPCTrack(name: String = Track.screenShareName,
                                      ipcName: String,
                                      source: VideoTrack.Source = .screenShareVideo) -> LocalVideoTrack {
        let videoSource = Engine.createVideoSource(forScreenShare: true)
        let capturer = IPCCapturer(delegate: videoSource, ipcName: ipcName)
        return LocalVideoTrack(
            name: name,
            source: source,
            capturer: capturer,
            videoSource: videoSource
        )
    }
}
