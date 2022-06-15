//
//  BroadcastScreenCapturer.m
//  RCTWebRTC
//
//  Created by Alex-Dan Bumbu on 06/01/2021.
//

import Foundation
import WebRTC
import Promises

class BroadcastScreenCapturer : BufferCapturer {
    private static let kRTCScreensharingSocketFD = "lk_SSFD"
    private static let kAppGroupIdentifierKey = "lkAppGroupIdentifier"
    
    var frameReader: SocketConnectionFrameReader?
    
    override func startCapture() -> Promise<Bool> {
        super.startCapture().then(on: .sdk) {didStart -> Promise<Bool> in
            
            guard didStart, self.frameReader == nil else {
                // already started
                return Promise(false)
            }
            
            guard let identifier = self.lookUpAppGroupIdentifier(),
                  let filePath = self.filePathForIdentifier(identifier)
            else {
                return Promise { false }
            }
            
            return Promise { fufill, _ in
                guard let socketConnection = BroadcastSocketConnection(filePath: filePath)
                else {
                    fufill(false)
                    return
                }
                let frameReader = SocketConnectionFrameReader()
                frameReader.didCapture = { pixelBuffer, rotation in
                    self.capture(pixelBuffer, rotation: rotation)
                    
                }
                frameReader.startCapture(with: socketConnection)
                self.frameReader = frameReader
                fufill(true)
            }
        }
    }
    
    override func stopCapture() -> Promise<Bool> {
        super.stopCapture().then(on: .sdk) { didStop -> Promise<Bool> in
            
            guard didStop, self.frameReader != nil else {
                // already stopped
                return Promise(false)
            }
            
            return Promise { fulfill, _ in
                self.frameReader?.stopCapture()
                self.frameReader = nil
                fulfill(true)
            }
        }
    }
    
    private func lookUpAppGroupIdentifier() -> String? {
        return Bundle.main.infoDictionary?[BroadcastScreenCapturer.kAppGroupIdentifierKey] as? String
    }
    
    private func filePathForIdentifier(_ identifier: String) -> String? {
        guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        else {
            return nil
        }
        
        let filePath = sharedContainer.appendingPathComponent(BroadcastScreenCapturer.kRTCScreensharingSocketFD).path
        return filePath
    }
    
}

extension LocalVideoTrack {
    /// Creates a track that captures screen capture from a broadcast upload extension
    @available(iOS 11.0, *)
    public static func createBroadcastScreenCapturerTrack(name: String = Track.screenShareVideoName,
                                                          source: VideoTrack.Source = .screenShareVideo,
                                                          options: BufferCaptureOptions = BufferCaptureOptions()) -> LocalVideoTrack {
        let videoSource = Engine.createVideoSource(forScreenShare: true)
        let capturer = BroadcastScreenCapturer(delegate: videoSource, options: options)
        return LocalVideoTrack(
            name: name,
            source: source,
            capturer: capturer,
            videoSource: videoSource
        )
    }
}
