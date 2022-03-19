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

public protocol PublishOptions {
    var name: String? { get }
}

public struct VideoPublishOptions: PublishOptions {

    public let name: String?
    /// preferred encoding parameters
    public let encoding: VideoEncoding?
    /// encoding parameters for for screen share
    public let screenShareEncoding: VideoEncoding?
    /// true to enable simulcasting, publishes three tracks at different sizes
    public let simulcast: Bool

    public let simulcastLayers: [VideoParameters]

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
}

public struct AudioPublishOptions: PublishOptions {

    public let name: String?
    public let bitrate: Int?
    public let dtx: Bool

    public init(name: String? = nil,
                bitrate: Int? = nil,
                dtx: Bool = true) {

        self.name = name
        self.bitrate = bitrate
        self.dtx = dtx
    }
}

public struct DataPublishOptions: PublishOptions {

    public let name: String?

    public init(name: String? = nil) {

        self.name = name
    }
}
