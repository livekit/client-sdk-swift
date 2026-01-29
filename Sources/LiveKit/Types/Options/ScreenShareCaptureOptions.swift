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

import Foundation

@objc
public final class ScreenShareCaptureOptions: NSObject, VideoCaptureOptions, Sendable {
    @objc
    public let dimensions: Dimensions

    @objc
    public let fps: Int

    /// Only used for macOS
    @objc
    public let showCursor: Bool

    @objc
    public let appAudio: Bool

    /// Preserve stereo for app audio during screen sharing (iOS only).
    ///
    /// When `true`, app audio is captured as a separate stereo track using `LocalAppAudioTrack`,
    /// bypassing the AudioDeviceModule to preserve stereo channels. When `false`, app audio
    /// is downmixed to mono through the audio mixer.
    ///
    /// Defaults to `true` when `appAudio` is enabled.
    @objc
    public let stereoAppAudio: Bool

    /// Use broadcast extension for screen capture (iOS only).
    ///
    /// If a broadcast extension has been properly configured, this defaults to `true`.
    ///
    @objc
    public let useBroadcastExtension: Bool

    @objc
    public let includeCurrentApplication: Bool

    /// Exclude windows by their window ID (macOS only).
    @objc
    public let excludeWindowIDs: [UInt32]

    public static let defaultToBroadcastExtension: Bool = {
        #if os(iOS)
        return BroadcastBundleInfo.hasExtension
        #else
        return false
        #endif
    }()

    public init(dimensions: Dimensions = .h1080_169,
                fps: Int = 30,
                showCursor: Bool = true,
                appAudio: Bool = false,
                stereoAppAudio: Bool? = nil,
                useBroadcastExtension: Bool = defaultToBroadcastExtension,
                includeCurrentApplication: Bool = false,
                excludeWindowIDs: [UInt32] = [])
    {
        self.dimensions = dimensions
        self.fps = fps
        self.showCursor = showCursor
        self.appAudio = appAudio
        // Default to true when appAudio is enabled, false otherwise
        self.stereoAppAudio = stereoAppAudio ?? appAudio
        self.useBroadcastExtension = useBroadcastExtension
        self.includeCurrentApplication = includeCurrentApplication
        self.excludeWindowIDs = excludeWindowIDs
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return dimensions == other.dimensions &&
            fps == other.fps &&
            showCursor == other.showCursor &&
            appAudio == other.appAudio &&
            stereoAppAudio == other.stereoAppAudio &&
            useBroadcastExtension == other.useBroadcastExtension &&
            includeCurrentApplication == other.includeCurrentApplication &&
            excludeWindowIDs == other.excludeWindowIDs
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(dimensions)
        hasher.combine(fps)
        hasher.combine(showCursor)
        hasher.combine(appAudio)
        hasher.combine(stereoAppAudio)
        hasher.combine(useBroadcastExtension)
        hasher.combine(includeCurrentApplication)
        hasher.combine(excludeWindowIDs)
        return hasher.finalize()
    }
}
