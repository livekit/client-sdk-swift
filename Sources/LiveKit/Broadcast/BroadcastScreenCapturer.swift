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
    private let appAudio: Bool
    private let stereoAppAudio: Bool
    private var receiver: BroadcastReceiver?

    /// Stereo app audio track (published separately from video).
    /// Only created when `stereoAppAudio` is `true`.
    private(set) var appAudioTrack: LocalAppAudioTrack?

    override func startCapture() async throws -> Bool {
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

        return createReceiver()
    }

    private func createReceiver() -> Bool {
        guard let socketPath = BroadcastBundleInfo.socketPath else {
            log("Bundle settings improperly configured for screen capture", .error)
            return false
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let receiver = try await BroadcastReceiver(socketPath: socketPath)
                log("Broadcast receiver connected", .debug)
                self.receiver = receiver

                if appAudio {
                    try await receiver.enableAudio()
                }

                var audioSampleCount = 0
                for try await sample in receiver.incomingSamples {
                    switch sample {
                    case let .image(buffer, rotation):
                        capture(buffer, rotation: rotation)
                    case let .audio(buffer):
                        audioSampleCount += 1
                        if audioSampleCount <= 5 || audioSampleCount % 100 == 0 {
                            log("[BroadcastScreenCapturer] Received audio sample #\(audioSampleCount), frames: \(buffer.frameLength), channels: \(buffer.format.channelCount), appAudioTrack: \(appAudioTrack != nil)")
                        }
                        if let appAudioTrack {
                            // Push directly to WebRTC (stereo preserved)
                            appAudioTrack.push(buffer)
                        } else {
                            // Legacy: Go through mixer (mono)
                            AudioManager.shared.mixer.capture(appAudio: buffer)
                        }
                    }
                }
                log("Broadcast receiver closed", .debug)
            } catch {
                log("Broadcast receiver error: \(error)", .error)
            }
            _ = try? await stopCapture()
        }
        return true
    }

    override func stopCapture() async throws -> Bool {
        let didStop = try await super.stopCapture()

        // Already stopped
        guard didStop else { return false }
        receiver?.close()
        appAudioTrack = nil
        return true
    }

    init(delegate: LKRTCVideoCapturerDelegate, options: ScreenShareCaptureOptions) {
        appAudio = options.appAudio
        stereoAppAudio = options.stereoAppAudio
        super.init(delegate: delegate, options: BufferCaptureOptions(from: options))

        // Create stereo app audio track early so it's available for auto-publish
        if options.appAudio, options.stereoAppAudio {
            appAudioTrack = LocalAppAudioTrack.createTrack(
                channelCount: 2,
                sampleRate: 48000
            )
            log("[BroadcastScreenCapturer] Created stereo app audio track: \(String(describing: appAudioTrack))")
        } else {
            log("[BroadcastScreenCapturer] Not creating app audio track. appAudio=\(options.appAudio), stereoAppAudio=\(options.stereoAppAudio)")
        }
    }
}

public extension LocalVideoTrack {
    /// Creates a track that captures screen capture from a broadcast upload extension
    static func createBroadcastScreenCapturerTrack(name: String = Track.screenShareVideoName,
                                                   source: Track.Source = .screenShareVideo,
                                                   options: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                                                   reportStatistics: Bool = false) -> LocalVideoTrack
    {
        let videoSource = RTC.createVideoSource(forScreenShare: true)
        let capturer = BroadcastScreenCapturer(delegate: videoSource, options: options)
        return LocalVideoTrack(
            name: name,
            source: source,
            capturer: capturer,
            videoSource: videoSource,
            reportStatistics: reportStatistics
        )
    }

    /// Returns the stereo app audio track if screen sharing with stereo app audio enabled.
    ///
    /// This track is created when using `createBroadcastScreenCapturerTrack` with
    /// `ScreenShareCaptureOptions(appAudio: true)` (stereoAppAudio defaults to true).
    ///
    /// Publish this track separately from the video track for stereo app audio:
    /// ```swift
    /// let screenTrack = LocalVideoTrack.createBroadcastScreenCapturerTrack(
    ///     options: ScreenShareCaptureOptions(appAudio: true)
    /// )
    /// try await room.localParticipant.publish(videoTrack: screenTrack)
    ///
    /// if let appAudioTrack = screenTrack.screenShareAppAudioTrack {
    ///     try await room.localParticipant.publish(
    ///         audioTrack: appAudioTrack,
    ///         options: AudioPublishOptions(stereo: true)
    ///     )
    /// }
    /// ```
    var screenShareAppAudioTrack: LocalAppAudioTrack? {
        (capturer as? BroadcastScreenCapturer)?.appAudioTrack
    }
}

#endif
