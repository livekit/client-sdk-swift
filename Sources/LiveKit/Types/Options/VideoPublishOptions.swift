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

    public let degradationPreference: DegradationPreference

    public let streamName: String?

    /// Proactive FlexFEC protection this client adds to the published track.
    ///
    /// `nil` keeps WebRTC's default, which adapts protection to the observed packet loss like
    /// ``FECProtection/adaptive``.
    ///
    /// - Note: Repairs are only sent when FlexFEC was negotiated, which requires
    ///   ``LiveKitSDK/setFlexFECEnabled(_:)`` and a server with upstream FlexFEC enabled.
    ///   WebRTC does not allocate a FlexFEC stream for simulcast, so a simulcast track does not
    ///   offer FlexFEC and this only takes effect with `simulcast: false`.
    public let fecProtection: FECProtection?

    public init(name: String? = nil,
                encoding: VideoEncoding? = nil,
                screenShareEncoding: VideoEncoding? = nil,
                simulcast: Bool = true,
                simulcastLayers: [VideoParameters] = [],
                screenShareSimulcastLayers: [VideoParameters] = [],
                preferredCodec: VideoCodec? = nil,
                preferredBackupCodec: VideoCodec? = nil,
                degradationPreference: DegradationPreference = .auto,
                streamName: String? = nil,
                fecProtection: FECProtection? = nil)
    {
        self.name = name
        self.encoding = encoding
        self.screenShareEncoding = screenShareEncoding
        self.simulcast = simulcast
        self.simulcastLayers = simulcastLayers
        self.screenShareSimulcastLayers = screenShareSimulcastLayers
        self.preferredCodec = preferredCodec
        self.preferredBackupCodec = preferredBackupCodec
        self.degradationPreference = degradationPreference
        self.streamName = streamName
        self.fecProtection = fecProtection
    }

    /// The initializer without `fecProtection`, which defaults to `nil`.
    /// Keeps code and binaries built against the earlier signature working.
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
                  degradationPreference: degradationPreference,
                  streamName: streamName,
                  fecProtection: nil)
    }

    // MARK: - Equal

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
            degradationPreference == other.degradationPreference &&
            streamName == other.streamName &&
            fecProtection == other.fecProtection
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
        hasher.combine(degradationPreference)
        hasher.combine(streamName)
        hasher.combine(fecProtection)
        return hasher.finalize()
    }
}
