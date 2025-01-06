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

import Foundation

@objc
public final class RoomOptions: NSObject, Sendable {
    // default options for capturing
    @objc
    public let defaultCameraCaptureOptions: CameraCaptureOptions

    @objc
    public let defaultScreenShareCaptureOptions: ScreenShareCaptureOptions

    @objc
    public let defaultAudioCaptureOptions: AudioCaptureOptions

    // default options for publishing
    @objc
    public let defaultVideoPublishOptions: VideoPublishOptions

    @objc
    public let defaultAudioPublishOptions: AudioPublishOptions

    @objc
    public let defaultDataPublishOptions: DataPublishOptions

    /// AdaptiveStream lets LiveKit automatically manage quality of subscribed
    /// video tracks to optimize for bandwidth and CPU.
    /// When attached video elements are visible, it'll choose an appropriate
    /// resolution based on the size of largest video element it's attached to.
    ///
    /// When none of the video elements are visible, it'll temporarily pause
    /// the data flow until they are visible again.
    ///
    @objc
    public let adaptiveStream: Bool

    /// Dynamically pauses video layers that are not being consumed by any subscribers,
    /// significantly reducing publishing CPU and bandwidth usage.
    ///
    @objc
    public let dynacast: Bool

    @objc
    public let stopLocalTrackOnUnpublish: Bool

    /// Automatically suspend(mute) local camera video tracks when the app enters background and
    /// resume(unmute) when the app enters foreground again.
    @objc
    public let suspendLocalVideoTracksInBackground: Bool

    /// E2EE Options
    public let e2eeOptions: E2EEOptions?

    @objc
    public let reportRemoteTrackStatistics: Bool

    override public init() {
        defaultCameraCaptureOptions = CameraCaptureOptions()
        defaultScreenShareCaptureOptions = ScreenShareCaptureOptions()
        defaultAudioCaptureOptions = AudioCaptureOptions()
        defaultVideoPublishOptions = VideoPublishOptions()
        defaultAudioPublishOptions = AudioPublishOptions()
        defaultDataPublishOptions = DataPublishOptions()
        adaptiveStream = false
        dynacast = false
        stopLocalTrackOnUnpublish = true
        suspendLocalVideoTracksInBackground = true
        e2eeOptions = nil
        reportRemoteTrackStatistics = false
    }

    @objc
    public init(defaultCameraCaptureOptions: CameraCaptureOptions = CameraCaptureOptions(),
                defaultScreenShareCaptureOptions: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                defaultAudioCaptureOptions: AudioCaptureOptions = AudioCaptureOptions(),
                defaultVideoPublishOptions: VideoPublishOptions = VideoPublishOptions(),
                defaultAudioPublishOptions: AudioPublishOptions = AudioPublishOptions(),
                defaultDataPublishOptions: DataPublishOptions = DataPublishOptions(),
                adaptiveStream: Bool = false,
                dynacast: Bool = false,
                stopLocalTrackOnUnpublish: Bool = true,
                suspendLocalVideoTracksInBackground: Bool = true,
                e2eeOptions: E2EEOptions? = nil,
                reportRemoteTrackStatistics: Bool = false)
    {
        self.defaultCameraCaptureOptions = defaultCameraCaptureOptions
        self.defaultScreenShareCaptureOptions = defaultScreenShareCaptureOptions
        self.defaultAudioCaptureOptions = defaultAudioCaptureOptions
        self.defaultVideoPublishOptions = defaultVideoPublishOptions
        self.defaultAudioPublishOptions = defaultAudioPublishOptions
        self.defaultDataPublishOptions = defaultDataPublishOptions
        self.adaptiveStream = adaptiveStream
        self.dynacast = dynacast
        self.stopLocalTrackOnUnpublish = stopLocalTrackOnUnpublish
        self.suspendLocalVideoTracksInBackground = suspendLocalVideoTracksInBackground
        self.e2eeOptions = e2eeOptions
        self.reportRemoteTrackStatistics = reportRemoteTrackStatistics
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return defaultCameraCaptureOptions == other.defaultCameraCaptureOptions &&
            defaultScreenShareCaptureOptions == other.defaultScreenShareCaptureOptions &&
            defaultAudioCaptureOptions == other.defaultAudioCaptureOptions &&
            defaultVideoPublishOptions == other.defaultVideoPublishOptions &&
            defaultAudioPublishOptions == other.defaultAudioPublishOptions &&
            defaultDataPublishOptions == other.defaultDataPublishOptions &&
            adaptiveStream == other.adaptiveStream &&
            dynacast == other.dynacast &&
            stopLocalTrackOnUnpublish == other.stopLocalTrackOnUnpublish &&
            suspendLocalVideoTracksInBackground == other.suspendLocalVideoTracksInBackground &&
            e2eeOptions == other.e2eeOptions &&
            reportRemoteTrackStatistics == other.reportRemoteTrackStatistics
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(defaultCameraCaptureOptions)
        hasher.combine(defaultScreenShareCaptureOptions)
        hasher.combine(defaultAudioCaptureOptions)
        hasher.combine(defaultVideoPublishOptions)
        hasher.combine(defaultAudioPublishOptions)
        hasher.combine(defaultDataPublishOptions)
        hasher.combine(adaptiveStream)
        hasher.combine(dynacast)
        hasher.combine(stopLocalTrackOnUnpublish)
        hasher.combine(suspendLocalVideoTracksInBackground)
        hasher.combine(e2eeOptions)
        hasher.combine(reportRemoteTrackStatistics)
        return hasher.finalize()
    }
}
