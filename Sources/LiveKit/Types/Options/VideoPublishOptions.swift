/*
 * Copyright 2022 LiveKit
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
public class VideoPublishOptions: NSObject, PublishOptions {

    @objc
    public let name: String?

    /// preferred encoding parameters
    @objc
    public let encoding: VideoEncoding?

    /// encoding parameters for for screen share
    @objc
    public let screenShareEncoding: VideoEncoding?

    /// true to enable simulcasting, publishes three tracks at different sizes
    @objc
    public let simulcast: Bool

    @objc
    public let simulcastLayers: [VideoParameters]

    @objc
    public let screenShareSimulcastLayers: [VideoParameters]

    public init(name: String? = nil,
                encoding: VideoEncoding? = nil,
                screenShareEncoding: VideoEncoding? = nil,
                simulcast: Bool = true,
                simulcastLayers: [VideoParameters] = [],
                screenShareSimulcastLayers: [VideoParameters] = []) {

        self.name = name
        self.encoding = encoding
        self.screenShareEncoding = screenShareEncoding
        self.simulcast = simulcast
        self.simulcastLayers = simulcastLayers
        self.screenShareSimulcastLayers = screenShareSimulcastLayers
    }

    // MARK: - Equal

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return self.name == other.name &&
            self.encoding == other.encoding &&
            self.screenShareEncoding == other.screenShareEncoding &&
            self.simulcast == other.simulcast &&
            self.simulcastLayers == other.simulcastLayers &&
            self.screenShareSimulcastLayers == other.screenShareSimulcastLayers
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(encoding)
        hasher.combine(screenShareEncoding)
        hasher.combine(simulcast)
        hasher.combine(simulcastLayers)
        hasher.combine(screenShareSimulcastLayers)
        return hasher.finalize()
    }
}
