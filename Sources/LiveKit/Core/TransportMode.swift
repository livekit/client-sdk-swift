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

internal import LiveKitWebRTC

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

    /// Resolve a signal target to the appropriate transport.
    func transport(for target: Livekit_SignalTarget) -> Transport {
        switch self {
        case let .publisherOnly(publisher):
            publisher
        case let .subscriberPrimary(publisher, subscriber), let .publisherPrimary(publisher, subscriber):
            target == .subscriber ? subscriber : publisher
        }
    }

    /// Close all transports.
    func close() async {
        await publisher.close()
        if !isSinglePeerConnection {
            await subscriber.close()
        }
    }

    /// Set RTC configuration on all transports.
    func set(configuration: LKRTCConfiguration) async throws {
        try await publisher.set(configuration: configuration)
        if !isSinglePeerConnection {
            try await subscriber.set(configuration: configuration)
        }
    }

    /// Mark the subscriber transport as restarting ICE (dual PC only, no-op in single PC).
    func setSubscriberRestartingIce() async {
        switch self {
        case .publisherOnly: break
        case let .subscriberPrimary(_, subscriber), let .publisherPrimary(_, subscriber):
            await subscriber.setIsRestartingIce()
        }
    }

    /// Returns the (previousAnswer, previousOffer) pair for sync state,
    /// which differs depending on the transport mode.
    func syncStateDescriptions() async -> (answer: LKRTCSessionDescription?, offer: LKRTCSessionDescription?) {
        switch self {
        case let .publisherOnly(publisher):
            await (publisher.remoteDescription, publisher.localDescription)
        case let .subscriberPrimary(_, subscriber), let .publisherPrimary(_, subscriber):
            await (subscriber.localDescription, subscriber.remoteDescription)
        }
    }
}
