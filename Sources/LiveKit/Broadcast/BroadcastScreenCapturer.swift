//
//  BroadcastScreenCapturer.m
//  RCTWebRTC
//
//  Created by Alex-Dan Bumbu on 06/01/2021.
//

import Foundation
import WebRTC
import Promises

#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)

class BroadcastScreenCapturer: BufferCapturer {
    static let kRTCScreensharingSocketFD = "rtc_SSFD"
    static let kAppGroupIdentifierKey = "RTCAppGroupIdentifier"
    static let kRTCScreenSharingExtension = "RTCScreenSharingExtension"

    var frameReader: SocketConnectionFrameReader?

    override func startCapture() -> Promise<Bool> {

        super.startCapture().then(on: queue) {didStart -> Promise<Bool> in

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
                let bounds = UIScreen.main.bounds
                let width = bounds.size.width
                let height = bounds.size.height
                let screenDimension = Dimensions(width: Int32(width), height: Int32(height))

                // pre fill dimensions, so that we don't have to wait for the broadcast to start to get actual dimensions.
                // should be able to safely predict using actual screen dimensions.
                let targetDimensions = screenDimension
                    .aspectFit(size: self.options.dimensions.max)
                    .toEncodeSafeDimensions()

                defer { self.dimensions = targetDimensions }
                let frameReader = SocketConnectionFrameReader()
                guard let socketConnection = BroadcastServerSocketConnection(filePath: filePath, streamDelegate: frameReader)
                else {
                    fufill(false)
                    return
                }
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

        super.stopCapture().then(on: queue) { didStop -> Promise<Bool> in

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
    public static func createBroadcastScreenCapturerTrack(name: String = Track.screenShareVideoName,
                                                          source: VideoTrack.Source = .screenShareVideo,
                                                          options: ScreenShareCaptureOptions = ScreenShareCaptureOptions()) -> LocalVideoTrack {
        let videoSource = Engine.createVideoSource(forScreenShare: true)
        let capturer = BroadcastScreenCapturer(delegate: videoSource, options: BufferCaptureOptions(from: options))
        return LocalVideoTrack(
            name: name,
            source: source,
            capturer: capturer,
            videoSource: videoSource
        )
    }
}

#endif
