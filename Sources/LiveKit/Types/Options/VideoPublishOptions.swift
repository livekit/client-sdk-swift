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

@objcMembers
public final class VideoPublishOptions: NSObject, TrackPublishOptions, Sendable {
    public let name: String?

    /// preferred encoding parameters
    public let encoding: VideoEncoding?

    /// encoding parameters for for screen share
    public let screenShareEncoding: VideoEncoding?

    /// true to enable simulcasting, publishes three tracks at different sizes
    public let simulcast: Bool

    public let simulcastLayers: [VideoParameters]

    public let screenShareSimulcastLayers: [VideoParameters]

    public let preferredCodec: VideoCodec?

    public let preferredBackupCodec: VideoCodec?

    /// Scalability mode used when publishing the **camera** with an SVC codec (VP9/AV1).
    /// `nil` keeps the default, `L3T3_KEY`. Ignored for non-SVC codecs (VP8/H264), which use
    /// simulcast instead, and ignored for screen share, which always uses `L1T3` because
    /// WebRTC does not publish SVC screen share with multiple spatial layers.
    ///
    /// Use `.L1T3` to publish a single spatial layer with temporal scalability — the same
    /// configuration `livekit-client` (JS) exposes as `scalabilityMode: 'L1T3'`. Motivation:
    /// with `L3T3_KEY` some SFU versions turn the dependency descriptor off for the track
    /// and subscribers freeze; a single spatial layer avoids it.
    public let scalabilityMode: ScalabilityMode?

    public let degradationPreference: DegradationPreference

    public let streamName: String?

    public init(name: String? = nil,
                encoding: VideoEncoding? = nil,
                screenShareEncoding: VideoEncoding? = nil,
                simulcast: Bool = true,
                simulcastLayers: [VideoParameters] = [],
                screenShareSimulcastLayers: [VideoParameters] = [],
                preferredCodec: VideoCodec? = nil,
                preferredBackupCodec: VideoCodec? = nil,
                scalabilityMode: ScalabilityMode? = nil,
                degradationPreference: DegradationPreference = .auto,
                streamName: String? = nil)
    {
        self.name = name
        self.encoding = encoding
        self.screenShareEncoding = screenShareEncoding
        self.simulcast = simulcast
        self.simulcastLayers = simulcastLayers
        self.screenShareSimulcastLayers = screenShareSimulcastLayers
        self.preferredCodec = preferredCodec
        self.preferredBackupCodec = preferredBackupCodec
        self.scalabilityMode = scalabilityMode
        self.degradationPreference = degradationPreference
        self.streamName = streamName
    }

    // MARK: - Equal

    /// Preserves the initializer available before `scalabilityMode` was added, with its original
    /// default arguments and its original Objective-C selector (derived, as the class is
    /// `@objcMembers`), so existing source and existing Objective-C binaries keep working.
    public convenience init(name: String? = nil,
                            encoding: VideoEncoding? = nil,
                            screenShareEncoding: VideoEncoding? = nil,
                            simulcast: Bool = true,
                            simulcastLayers: [VideoParameters] = [],
                            screenShareSimulcastLayers: [VideoParameters] = [],
                            preferredCodec: VideoCodec? = nil,
                            preferredBackupCodec: VideoCodec? = nil,
                            degradationPreference: DegradationPreference = .auto,
                            streamName: String? = nil)
    {
        self.init(name: name,
                  encoding: encoding,
                  screenShareEncoding: screenShareEncoding,
                  simulcast: simulcast,
                  simulcastLayers: simulcastLayers,
                  screenShareSimulcastLayers: screenShareSimulcastLayers,
                  preferredCodec: preferredCodec,
                  preferredBackupCodec: preferredBackupCodec,
                  scalabilityMode: nil,
                  degradationPreference: degradationPreference,
                  streamName: streamName)
    }

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return name == other.name &&
            encoding == other.encoding &&
            screenShareEncoding == other.screenShareEncoding &&
            simulcast == other.simulcast &&
            simulcastLayers == other.simulcastLayers &&
            screenShareSimulcastLayers == other.screenShareSimulcastLayers &&
            preferredCodec == other.preferredCodec &&
            preferredBackupCodec == other.preferredBackupCodec &&
            scalabilityMode == other.scalabilityMode &&
            degradationPreference == other.degradationPreference &&
            streamName == other.streamName
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(encoding)
        hasher.combine(screenShareEncoding)
        hasher.combine(simulcast)
        hasher.combine(simulcastLayers)
        hasher.combine(screenShareSimulcastLayers)
        hasher.combine(preferredCodec)
        hasher.combine(preferredBackupCodec)
        hasher.combine(scalabilityMode)
        hasher.combine(degradationPreference)
        hasher.combine(streamName)
        return hasher.finalize()
    }
}
