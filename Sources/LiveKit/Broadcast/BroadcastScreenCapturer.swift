/*
 * Copyright 2025 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if os(iOS)

import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

class BroadcastScreenCapturer: BufferCapturer {
    var frameReader: SocketConnectionFrameReader?

    override func startCapture() async throws -> Bool {
        let didStart = try await super.startCapture()

        guard didStart else { return false }

        guard let groupIdentifier = Self.groupIdentifier,
              let socketPath = Self.socketPath(for: groupIdentifier)
        else {
            logger.error("Bundle settings improperly configured for screen capture")
            return false
        }

        let bounds = await UIScreen.main.bounds
        let width = bounds.size.width
        let height = bounds.size.height
        let screenDimension = Dimensions(width: Int32(width), height: Int32(height))

        // pre fill dimensions, so that we don't have to wait for the broadcast to start to get actual dimensions.
        // should be able to safely predict using actual screen dimensions.
        let targetDimensions = screenDimension
            .aspectFit(size: options.dimensions.max)
            .toEncodeSafeDimensions()

        set(dimensions: targetDimensions)

        let frameReader = SocketConnectionFrameReader()
        guard let socketConnection = BroadcastServerSocketConnection(filePath: socketPath, streamDelegate: frameReader)
        else { return false }
        frameReader.didCapture = { pixelBuffer, rotation in
            self.capture(pixelBuffer, rotation: rotation.toLKType())
        }
        frameReader.didEnd = { [weak self] in
            guard let self else { return }
            Task {
                try await self.stopCapture()
            }
        }
        frameReader.startCapture(with: socketConnection)
        self.frameReader = frameReader

        return true
    }

    override func stopCapture() async throws -> Bool {
        let didStop = try await super.stopCapture()

        // Already stopped
        guard didStop else { return false }

        frameReader?.stopCapture()
        frameReader = nil
        return true
    }

    /// Identifier of the app group shared by the primary app and broadcast extension.
    @BundleInfo("RTCAppGroupIdentifier")
    static var groupIdentifier: String?

    /// Bundle identifier of the broadcast extension.
    @BundleInfo("RTCScreenSharingExtension")
    static var screenSharingExtension: String?

    /// Path to the socket file used for interprocess communication.
    static var socketPath: String? {
        guard let groupIdentifier = Self.groupIdentifier else { return nil }
        return Self.socketPath(for: groupIdentifier)
    }

    private static let kRTCScreensharingSocketFD = "rtc_SSFD"

    private static func socketPath(for groupIdentifier: String) -> String? {
        guard let sharedContainer = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
        else { return nil }
        return sharedContainer.appendingPathComponent(Self.kRTCScreensharingSocketFD).path
    }
}

public extension LocalVideoTrack {
    /// Creates a track that captures screen capture from a broadcast upload extension
    static func createBroadcastScreenCapturerTrack(name: String = Track.screenShareVideoName,
                                                   source: VideoTrack.Source = .screenShareVideo,
                                                   options: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                                                   reportStatistics: Bool = false) -> LocalVideoTrack
    {
        let videoSource = RTC.createVideoSource(forScreenShare: true)
        let capturer = BroadcastScreenCapturer(delegate: videoSource, options: BufferCaptureOptions(from: options))
        return LocalVideoTrack(
            name: name,
            source: source,
            capturer: capturer,
            videoSource: videoSource,
            reportStatistics: reportStatistics
        )
    }
}

#endif
