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

enum TransportMode: Equatable, Sendable {
    /// Single peer connection: publisher handles both publishing and receiving.
    case publisherOnly(publisher: Transport)
    /// Dual peer connection with subscriber as primary (default).
    case subscriberPrimary(publisher: Transport, subscriber: Transport)
    /// Dual peer connection with publisher as primary.
    case publisherPrimary(publisher: Transport, subscriber: Transport)
}

extension TransportMode {
    /// The transport used for publishing local tracks. Always the publisher.
    var publisher: Transport {
        switch self {
        case let .publisherOnly(publisher): publisher
        case let .subscriberPrimary(publisher, _): publisher
        case let .publisherPrimary(publisher, _): publisher
        }
    }

    /// The transport used for receiving remote tracks and server-opened data channels.
    /// In single PC mode this is the publisher; in dual PC mode this is the subscriber.
    var subscriber: Transport {
        switch self {
        case let .publisherOnly(publisher): publisher
        case let .subscriberPrimary(_, subscriber): subscriber
        case let .publisherPrimary(_, subscriber): subscriber
        }
    }

    var isSinglePeerConnection: Bool {
        if case .publisherOnly = self { return true }
        return false
    }

    var isSubscriberPrimary: Bool {
        if case .subscriberPrimary = self { return true }
        return false
    }
}
