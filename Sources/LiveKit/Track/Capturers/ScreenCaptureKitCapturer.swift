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
import CoreMedia
import Foundation

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

internal import LiveKitWebRTC

#if compiler(>=6.4) && !COCOAPODS
internal import LKObjCHelpers
#endif

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
public final class ScreenCaptureKitCapturer: VideoCapturer, @unchecked Sendable {
    private let capturer = RTC.createVideoCapturer()

    /// The ``ScreenShareCaptureOptions`` used for this capturer.
    public let options: ScreenShareCaptureOptions

    /// When `true`, only the current application is captured (in-app capture). When `false`, the
    /// user may select system-wide content, including other apps.
    public let captureCurrentApplicationOnly: Bool

    private struct State {
        var stream: SCStream?
        var startTask: AnyTaskCancellable?
    }

    private let _scState = StateSync(State())

    init(delegate: LKRTCVideoCapturerDelegate,
         options: ScreenShareCaptureOptions,
         captureCurrentApplicationOnly: Bool)
    {
        self.options = options
        self.captureCurrentApplicationOnly = captureCurrentApplicationOnly
        super.init(delegate: delegate)
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

        if let stream = _scState.read({ $0.stream }) {
            try await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
            if options.appAudio {
                try? stream.removeStreamOutput(self, type: .audio)
            }
        }

        _scState.mutate {
            $0.stream = nil
            $0.startTask = nil
        }

        return true
    }

    private func startStream(with filter: SCContentFilter) {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = options.appAudio

        // `pixelFormat` is unavailable on iOS; the default format is forwarded as-is and filtered
        // against `VideoCapturer.supportedPixelFormats` before reaching WebRTC.
        let target = options.dimensions.toEncodeSafeDimensions()
        #if compiler(>=6.4) && !COCOAPODS
        // `SCStreamConfiguration.width`/`.height` are `size_t`, whose Swift setter is rejected by
        // the Xcode 27 importer; reach them from Obj-C instead (mirrors ``MacOSScreenCapturer``).
        LKObjCHelpers.setWidth(Int(target.width), height: Int(target.height), on: configuration)
        #else
        configuration.width = Int(target.width)
        configuration.height = Int(target.height)
        #endif

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
            if options.appAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
            }
        } catch {
            log("Failed to add SCStream output: \(error)", .error)
            return
        }

        _scState.mutate { $0.stream = stream }

        let task = Task.detached { [weak self] in
            guard let self, let stream = _scState.read({ $0.stream }) else { return }
            do {
                try await stream.startCapture()
            } catch {
                log("Failed to start SCStream: \(error)", .error)
            }
        }.cancellable()

        _scState.mutate { $0.startTask = task }
    }
}

// MARK: - SCContentSharingPickerObserver

@available(iOS 27.0, *)
extension ScreenCaptureKitCapturer: SCContentSharingPickerObserver {
    public func contentSharingPicker(_: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for _: SCStream?) {
        guard _scState.read({ $0.stream == nil }) else {
            log("Ignoring content picker re-selection; a stream is already running", .debug)
            return
        }
        startStream(with: filter)
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

// MARK: - SCStreamDelegate

@available(iOS 27.0, *)
extension ScreenCaptureKitCapturer: SCStreamDelegate {
    public func stream(_: SCStream, didStopWithError error: any Error) {
        log("SCStream stopped with error: \(error)", .error)
        Task.discarding { [weak self] in
            try await self?.stopCapture()
        }
    }
}

// MARK: - SCStreamOutput

@available(iOS 27.0, *)
extension ScreenCaptureKitCapturer: SCStreamOutput {
    public func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard case .started = captureState else { return }
        guard sampleBuffer.isValid else { return }

        switch outputType {
        case .audio:
            guard options.appAudio, let pcm = sampleBuffer.toAVAudioPCMBuffer() else { return }
            AudioManager.shared.mixer.capture(appAudio: pcm)
        case .screen:
            // Forward only fully rendered frames; idle/blank/suspended frames carry no new content.
            if let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
               let statusRawValue = attachments[.status] as? Int,
               let status = SCFrameStatus(rawValue: statusRawValue),
               status != .complete
            {
                return
            }
            capture(sampleBuffer: sampleBuffer, capturer: capturer, options: options)
        default:
            break
        }
    }
}

public extension LocalVideoTrack {
    /// Creates a screen-share track backed by ScreenCaptureKit (iOS 27+), without a Broadcast Upload Extension.
    ///
    /// - Parameter captureCurrentApplicationOnly: When `true`, restricts capture to the current
    ///   application. When `false`, the system picker allows selecting system-wide content.
    @available(iOS 27.0, *)
    static func createScreenCaptureKitTrack(name: String = Track.screenShareVideoName,
                                            options: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                                            captureCurrentApplicationOnly: Bool = false,
                                            reportStatistics: Bool = false) -> LocalVideoTrack
    {
        let videoSource = RTC.createVideoSource(forScreenShare: true)
        let capturer = ScreenCaptureKitCapturer(delegate: videoSource,
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
