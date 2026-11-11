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
    private static let activeReceivers = StateSync(Set<UUID>())
    static var activeCount: Int { activeReceivers.read { $0.count } }

    private let appAudio: Bool
    private let socketPath: SocketPath?
    private let receiverTask = StateSync<(id: UUID, task: AnyTaskCancellable)?>(nil)
    private let captureSerialRunner = SerialRunnerActor<Bool>()

    override func startCapture() async throws -> Bool {
        try await captureSerialRunner.run { try await self.startReceiver() }
    }

    private func startReceiver() async throws -> Bool {
        let didStart = try await super.startCapture()

        guard didStart else { return false }

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

        guard createReceiver() else {
            // Balance the counter so the capturer does not report `.started`
            // while no capture is running.
            _ = try? await stopCapture()
            return false
        }
        return true
    }

    private func createReceiver() -> Bool {
        guard let socketPath else {
            log("Bundle settings improperly configured for screen capture", .error)
            return false
        }
        let isAnotherActive = receiverTask.mutate { receiverTask in
            let id = UUID()
            let isAnotherActive = Self.activeReceivers.mutate {
                $0.insert(id)
                return $0.count > 1
            }
            let task = Task { [weak self] in
                // Stop and task completion may both remove this receiver, including after a restart.
                defer { Self.activeReceivers.mutate { $0.remove(id) } }
                guard !Task.isCancelled else { return }
                await self?.receive(from: socketPath)
            }.cancellable()
            receiverTask = (id, task)
            return isAnotherActive
        }
        if isAnotherActive {
            log("Another broadcast screen share is already active, only one of them receives the broadcast", .warning)
        }
        return true
    }

    private func receive(from socketPath: SocketPath) async {
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
        guard !Task.isCancelled else { return }
        _ = try? await stopCapture()
    }

    override func stopCapture() async throws -> Bool {
        try await captureSerialRunner.run { try await self.stopReceiver() }
    }

    private func stopReceiver() async throws -> Bool {
        let didStop = try await super.stopCapture()

        // Already stopped
        guard didStop else { return false }
        if let receiver = receiverTask.mutate({ receiver in
            let current = receiver
            receiver = nil
            return current
        }) {
            Self.activeReceivers.mutate { $0.remove(receiver.id) }
            receiver.task.cancel()
        }
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
