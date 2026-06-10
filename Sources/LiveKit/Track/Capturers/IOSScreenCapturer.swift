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

#if os(iOS) && !targetEnvironment(macCatalyst)

import AVFoundation
import Foundation

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

internal import LiveKitWebRTC

#if canImport(ScreenCaptureKit)

/// A ``VideoCapturer`` backed by ScreenCaptureKit, available on iOS 27 and later.
///
/// Unlike ``BroadcastScreenCapturer``, this capturer runs entirely in-process via `SCStream` and
/// does **not** require a Broadcast Upload Extension or an app group. Content is selected through
/// the system ``ScreenCaptureKit/SCContentSharingPicker``; capture begins once the user makes a
/// selection and the picker delivers an `SCContentFilter`.
///
/// - Note: System-wide capture (across other apps) continues while the app is backgrounded only if
///   the app declares the appropriate background mode. Without it, the stream stops with
///   `SCStreamError.Code.missingBackgroundMode`.
/// - Warning: Experimental prototype for evaluating a ReplayKit-free screen-share path on iOS 27+.
@available(iOS 27.0, *)
public final class IOSScreenCapturer: SCStreamVideoCapturer, @unchecked Sendable {
    /// When `true`, only the current application is captured (in-app capture). When `false`, the
    /// user may select system-wide content, including other apps.
    public let captureCurrentApplicationOnly: Bool

    init(delegate: LKRTCVideoCapturerDelegate,
         options: ScreenShareCaptureOptions,
         captureCurrentApplicationOnly: Bool)
    {
        self.captureCurrentApplicationOnly = captureCurrentApplicationOnly
        super.init(delegate: delegate, options: options)
    }

    override public func startCapture() async throws -> Bool {
        let didStart = try await super.startCapture()

        // Already started
        guard didStart else { return false }

        try await MainActor.run {
            let picker = SCContentSharingPicker.shared
            guard picker.isAvailable else {
                throw LiveKitError(.invalidState, message: "Screen capture is not available on this device")
            }

            var configuration = SCContentSharingPickerConfiguration()
            // App audio (if requested) is captured directly from the stream, so the picker's own
            // microphone affordance is not needed here.
            configuration.showsMicrophoneControl = false
            picker.defaultConfiguration = configuration

            picker.add(self)
            picker.isActive = true

            if captureCurrentApplicationOnly {
                picker.presentForCurrentApplication()
            } else {
                picker.present()
            }
        }

        return true
    }

    override public func stopCapture() async throws -> Bool {
        let didStop = try await super.stopCapture()

        // Already stopped
        guard didStop else { return false }

        await MainActor.run {
            let picker = SCContentSharingPicker.shared
            picker.isActive = false
            picker.remove(self)
        }

        try await teardownStream()

        return true
    }
}

// MARK: - SCContentSharingPickerObserver

@available(iOS 27.0, *)
extension IOSScreenCapturer: SCContentSharingPickerObserver {
    public func contentSharingPicker(_: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for _: SCStream?) {
        guard scStream == nil else {
            log("Ignoring content picker re-selection; a stream is already running", .debug)
            return
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = options.appAudio
        let target = options.dimensions.toEncodeSafeDimensions()
        setSize(width: Int(target.width), height: Int(target.height), on: configuration)

        do {
            _ = try makeStream(filter: filter, configuration: configuration)
        } catch {
            log("Failed to create SCStream: \(error)", .error)
            return
        }

        let task = Task.detached { [weak self] in
            guard let self, let stream = scStream else { return }
            do {
                try await stream.startCapture()
            } catch {
                log("Failed to start SCStream: \(error)", .error)
            }
        }.cancellable()

        _screenCapturerState.mutate { $0.startTask = task }
    }

    public func contentSharingPicker(_: SCContentSharingPicker, didCancelFor _: SCStream?) {
        log("Content sharing picker cancelled by user", .debug)
        Task.discarding { [weak self] in
            try await self?.stopCapture()
        }
    }

    public func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        log("Content sharing picker failed to start: \(error)", .error)
    }
}

public extension LocalVideoTrack {
    /// Creates a screen-share track backed by ScreenCaptureKit (iOS 27+), without a Broadcast Upload Extension.
    ///
    /// - Parameter captureCurrentApplicationOnly: When `true`, restricts capture to the current
    ///   application. When `false`, the system picker allows selecting system-wide content.
    @available(iOS 27.0, *)
    static func createIOSScreenShareTrack(name: String = Track.screenShareVideoName,
                                          options: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                                          captureCurrentApplicationOnly: Bool = false,
                                          reportStatistics: Bool = false) -> LocalVideoTrack
    {
        let videoSource = RTC.createVideoSource(forScreenShare: true)
        let capturer = IOSScreenCapturer(delegate: videoSource,
                                         options: options,
                                         captureCurrentApplicationOnly: captureCurrentApplicationOnly)
        return LocalVideoTrack(name: name,
                               source: .screenShareVideo,
                               capturer: capturer,
                               videoSource: videoSource,
                               reportStatistics: reportStatistics)
    }
}

#endif

#endif
