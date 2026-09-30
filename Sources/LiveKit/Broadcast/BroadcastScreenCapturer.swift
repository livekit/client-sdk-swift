/*
 * Copyright 2026 LiveKit
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

internal import LiveKitWebRTC

class BroadcastScreenCapturer: BufferCapturer, @unchecked Sendable {
    private static let activeCount = StateSync(0)

    private let appAudio: Bool
    private let socketPath: SocketPath?
    private let receiverTask = StateSync<AnyTaskCancellable?>(nil)

    override func startCapture() async throws -> Bool {
        let didStart = try await super.startCapture()

        guard didStart else { return false }

        if Self.activeCount.mutate({ $0 += 1; return $0 > 1 }) {
            log("Another broadcast screen share is already active, only one of them receives the broadcast", .warning)
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
        return createReceiver()
    }

    private func createReceiver() -> Bool {
        guard let socketPath else {
            log("Bundle settings improperly configured for screen capture", .error)
            return false
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let receiver = try await BroadcastReceiver(socketPath: socketPath)
                log("Broadcast receiver connected", .debug)

                try await withTaskCancellationHandler {
                    if appAudio {
                        try await receiver.enableAudio()
                    }

                    for try await sample in receiver.incomingSamples {
                        switch sample {
                        case let .image(buffer, rotation): capture(buffer, rotation: rotation)
                        case let .audio(buffer): AudioManager.shared.mixer.capture(appAudio: buffer)
                        }
                    }
                } onCancel: {
                    receiver.close()
                }
                log("Broadcast receiver closed", .debug)
            } catch {
                log("Broadcast receiver error: \(error)", Task.isCancelled ? .debug : .error)
            }
            _ = try? await stopCapture()
        }
        receiverTask.mutate { $0 = task.cancellable() }
        return true
    }

    override func stopCapture() async throws -> Bool {
        let didStop = try await super.stopCapture()

        // Already stopped
        guard didStop else { return false }
        Self.activeCount.mutate { $0 -= 1 }
        receiverTask.copy()?.cancel()
        return true
    }

    init(delegate: LKRTCVideoCapturerDelegate,
         options: ScreenShareCaptureOptions,
         socketPath: SocketPath? = BroadcastBundleInfo.socketPath)
    {
        appAudio = options.appAudio
        self.socketPath = socketPath
        super.init(delegate: delegate, options: BufferCaptureOptions(from: options))
    }
}

public extension LocalVideoTrack {
    /// Creates a track that captures screen capture from a broadcast upload extension
    @available(*, deprecated, message: "Blocks the calling thread until WebRTC's factory responds; use the async variant instead.")
    static func createBroadcastScreenCapturerTrack(name: String = Track.screenShareVideoName,
                                                   source: Track.Source = .screenShareVideo,
                                                   options: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                                                   reportStatistics: Bool = false) -> LocalVideoTrack
    {
        _createBroadcastScreenCapturerTrack(name: name, source: source, options: options, reportStatistics: reportStatistics)
    }

    /// Creates a broadcast screen-share track on the RTC executor: the calling task suspends
    /// instead of blocking its thread on WebRTC's factory.
    static func createBroadcastScreenCapturerTrack(name: String = Track.screenShareVideoName,
                                                   source: Track.Source = .screenShareVideo,
                                                   options: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                                                   reportStatistics: Bool = false) async -> LocalVideoTrack
    {
        await RTC.run { _createBroadcastScreenCapturerTrack(name: name, source: source, options: options, reportStatistics: reportStatistics) }
    }

    internal static func _createBroadcastScreenCapturerTrack(name: String,
                                                             source: Track.Source,
                                                             options: ScreenShareCaptureOptions,
                                                             reportStatistics: Bool) -> LocalVideoTrack
    {
        let videoSource = RTC.createVideoSource(forScreenShare: true)
        let capturer = BroadcastScreenCapturer(delegate: videoSource, options: options)
        return LocalVideoTrack(
            name: name,
            source: source,
            capturer: capturer,
            videoSource: videoSource,
            reportStatistics: reportStatistics,
        )
    }
}

#endif
