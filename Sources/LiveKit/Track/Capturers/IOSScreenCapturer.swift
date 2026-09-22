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

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(ScreenCaptureKit)

import AVFoundation
import Foundation
import ScreenCaptureKit

internal import LiveKitWebRTC

/// A ``VideoCapturer`` backed by ScreenCaptureKit, available on iOS 27 and later.
///
/// Unlike ``BroadcastScreenCapturer``, this capturer runs entirely in-process via `SCStream` and
/// does **not** require a Broadcast Upload Extension or an app group. Content is selected through
/// the system ``ScreenCaptureKit/SCContentSharingPicker``; capture begins once the user makes a
/// selection and the picker delivers an `SCContentFilter`.
///
/// ``startCapture()`` presents the picker and does not return until the user has chosen content and
/// the stream has started; it throws ``LiveKitError/Type-swift.enum/cancelled`` if the user dismisses
/// the picker, so a track is never published for a share that never began.
///
/// - Note: System-wide capture (across other apps) continues while the app is backgrounded only if
///   the app declares the appropriate background mode. Without it, the stream stops with
///   `SCStreamError.Code.missingBackgroundMode`.
/// - Note: ``ScreenShareCaptureOptions/fps`` has no effect here: `SCStreamConfiguration`'s
///   `minimumFrameInterval` is unavailable on iOS, so the system picks the rate.
@available(iOS 27.0, *)
public final class IOSScreenCapturer: ScreenCapturer, @unchecked Sendable {
    /// When `true`, only the current application is captured (in-app capture). When `false`, the
    /// user may select system-wide content, including other apps.
    public let captureCurrentApplicationOnly: Bool

    private let _isPresentingPicker = StateSync(false)

    // `SCContentFilter` is not `Sendable`, so it is handed over through `StateSync` rather than
    // as the completer's value.
    private let _pickedFilter = StateSync<SCContentFilter?>(nil)
    private let _pickerCompleter = AsyncCompleter<Void>(label: "Content sharing picker",
                                                        defaultTimeout: .defaultScreenSharePicker)

    /// Whether the system content picker can be presented, and so whether this capturer is usable.
    @MainActor
    static var isAvailable: Bool { SCContentSharingPicker.shared.isAvailable }

    /// Aborts a selection that ``startCapture()`` is currently waiting on, making it throw
    /// ``LiveKitError/Type-swift.enum/cancelled``.
    ///
    /// ``LocalParticipant/set(source:enabled:captureOptions:publishOptions:)`` serializes its work, so
    /// a request to stop sharing would otherwise queue behind the picker until the user answers it.
    func cancelPendingPick() {
        _pickerCompleter.resume(throwing: LiveKitError(.cancelled, message: "Screen share cancelled"))
    }

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

        // The completer caches its result, so clear it once this attempt is over rather than when
        // the next one starts — a cancellation can arrive before the picker is even presented.
        defer {
            _pickerCompleter.rearm()
            _pickedFilter.mutate { $0 = nil }
        }

        do {
            try await presentPicker()
            // Capture only begins once the user picks content; surfacing the wait here keeps a
            // cancelled picker from publishing an empty track.
            try await _pickerCompleter.wait()
            guard let filter = _pickedFilter.read({ $0 }) else {
                throw LiveKitError(.invalidState, message: "Content picker resolved without a selection")
            }
            try await startStream(with: filter)
            // Only one selection is honored; further picker updates would have nothing to resume.
            await dismissPicker()
        } catch {
            // Unconditional: an overlapping `startCapture()` would leave the counter above zero, so
            // `stopCapture()` would decline to clean up after this attempt.
            await releasePicker()
            // Rebalance the counter `super.startCapture()` incremented; report the original failure.
            _ = try? await super.stopCapture()
            throw error
        }

        return true
    }

    private func presentPicker() async throws {
        try await MainActor.run {
            let picker = SCContentSharingPicker.shared
            guard picker.isAvailable else {
                throw LiveKitError(.invalidState, message: "Screen capture is not available on this device")
            }
            // The picker is process-wide and delivers one selection to every observer, so only one
            // capturer may present it at a time; `isActive` is that claim, flipped on the main actor.
            guard !picker.isActive else {
                throw LiveKitError(.invalidState, message: "Another screen share is already presenting the content picker")
            }

            picker.add(self)
            picker.isActive = true
            _isPresentingPicker.mutate { $0 = true }

            if captureCurrentApplicationOnly {
                picker.presentForCurrentApplication()
            } else {
                picker.present()
            }
        }
    }

    private func dismissPicker() async {
        // Only the capturer that presented may deactivate, and only once.
        let didPresent = _isPresentingPicker.mutate { didPresent -> Bool in
            defer { didPresent = false }
            return didPresent
        }
        guard didPresent else { return }

        await MainActor.run {
            let picker = SCContentSharingPicker.shared
            picker.isActive = false
            picker.remove(self)
        }
    }

    private func startStream(with filter: SCContentFilter) async throws {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = options.appAudio
        let target = options.dimensions.toEncodeSafeDimensions()
        configuration.width = Int(target.width)
        configuration.height = Int(target.height)

        let stream = try makeStream(filter: filter, configuration: configuration)
        try await stream.startCapture()
    }

    override public func stopCapture() async throws -> Bool {
        let didStop = try await super.stopCapture()

        // Already stopped
        guard didStop else { return false }

        await releasePicker()

        return true
    }

    /// Dismisses the picker and releases the stream, whatever stage this attempt reached.
    private func releasePicker() async {
        await dismissPicker()
        // `makeStream` may already have registered outputs before a failure.
        await teardownStream()
    }
}

// MARK: - SCContentSharingPickerObserver

@available(iOS 27.0, *)
extension IOSScreenCapturer: SCContentSharingPickerObserver {
    public func contentSharingPicker(_: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for _: SCStream?) {
        _pickedFilter.mutate { $0 = filter }
        _pickerCompleter.resume(returning: ())
    }

    public func contentSharingPicker(_: SCContentSharingPicker, didCancelFor _: SCStream?) {
        log("Content sharing picker cancelled by user", .debug)
        _pickerCompleter.resume(throwing: LiveKitError(.cancelled, message: "Screen share cancelled by user"))
    }

    public func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        log("Content sharing picker failed to start: \(error)", .error)
        _pickerCompleter.resume(throwing: LiveKitError.from(error: error) ?? LiveKitError(.invalidState))
    }
}

public extension LocalVideoTrack {
    /// Creates a screen-share track backed by ScreenCaptureKit (iOS 27+), without a Broadcast Upload Extension.
    ///
    /// Starting the returned track presents the system content picker and waits for the user's
    /// selection, so publishing fails rather than succeeding with a track that carries no frames.
    /// Runs on the RTC executor: the calling task suspends instead of blocking its thread on
    /// WebRTC's factory.
    ///
    /// - Parameter captureCurrentApplicationOnly: When `true`, restricts capture to the current
    ///   application. When `false`, the system picker allows selecting system-wide content.
    @available(iOS 27.0, *)
    static func createIOSScreenShareTrack(name: String = Track.screenShareVideoName,
                                          options: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                                          captureCurrentApplicationOnly: Bool = false,
                                          reportStatistics: Bool = false) async -> LocalVideoTrack
    {
        await RTC.run {
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
}

#endif
