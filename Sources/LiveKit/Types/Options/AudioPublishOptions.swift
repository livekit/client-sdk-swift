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
public final class AudioPublishOptions: NSObject, TrackPublishOptions, Sendable {
    @objc
    public let name: String?

    /// preferred encoding parameters
    @objc
    public let encoding: AudioEncoding?

    @objc
    public let dtx: Bool

    @objc
    public let red: Bool

    @objc
    public let streamName: String?

    @objc
    public let preConnect: Bool

    public init(name: String? = nil,
                encoding: AudioEncoding? = nil,
                dtx: Bool = true,
                red: Bool = true,
                streamName: String? = nil,
                preConnect: Bool = false)
    {
        self.name = name
        self.encoding = encoding
        self.dtx = dtx
        self.red = red
        self.streamName = streamName
        self.preConnect = preConnect
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return name == other.name &&
            encoding == other.encoding &&
            dtx == other.dtx &&
            red == other.red &&
            streamName == other.streamName &&
            preConnect == other.preConnect
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(encoding)
        hasher.combine(dtx)
        hasher.combine(red)
        hasher.combine(streamName)
        hasher.combine(preConnect)
        return hasher.finalize()
    }
}

// Internal
extension AudioPublishOptions {
    func toFeatures() -> Set<Livekit_AudioTrackFeature> {
        Set([
            !dtx ? .tfNoDtx : nil,
            preConnect ? .tfPreconnectBuffer : nil,
        ].compactMap { $0 })
    }
}

extension AudioPublishOptions {
    func withPreconnect(_ enabled: Bool) -> AudioPublishOptions {
        AudioPublishOptions(
            name: name,
            encoding: encoding,
            dtx: dtx,
            red: red,
            streamName: streamName,
            preConnect: enabled
        )
    }
}
