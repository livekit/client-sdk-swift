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

internal import LiveKitWebRTC

// MARK: - Connection dependencies

/// Subsystems scoped to one connection: created by `Room.connect()`, carried across a full
/// reconnect, released on disconnect.
///
/// Membership in this type is the survival policy: a full reconnect retires the
/// ``JoinDependencies`` built on top of it and keeps this value; a disconnect retires both.
final class ConnectionDependencies: Sendable {
    /// The data track subsystem (managers, channels, signal/packet routing) behind one reference.
    /// Across a full reconnect only its transport channels are swapped so published tracks can be
    /// republished.
    let dataTracks: DataTracks

    /// The E2EE manager, derived from the room options. A synchronized cell rather than a `let`:
    /// the public ``Room/e2eeManager`` setter writes through it, so the value stays swappable
    /// while its lifetime is the connection's.
    let e2ee: StateSync<E2EEManager?>

    init(room: Room, roomOptions: RoomOptions) {
        dataTracks = DataTracks(room: room)
        let manager: E2EEManager? = if let e2eeOptions = roomOptions.e2eeOptions {
            E2EEManager(e2eeOptions: e2eeOptions)
        } else if let encryptionOptions = roomOptions.encryptionOptions {
            E2EEManager(options: encryptionOptions)
        } else {
            nil
        }
        e2ee = StateSync(manager)
    }

    /// Ordered teardown, called with the retired value after ``DependencyStage/end()``.
    func tearDown() {
        e2ee.copy()?.cleanUp(isFullReconnect: false)
    }
}

extension ConnectionDependencies: Equatable {
    static func == (lhs: ConnectionDependencies, rhs: ConnectionDependencies) -> Bool { lhs === rhs }
}

// MARK: - Early publisher

/// A publisher peer connection built *before* the signal socket opens, so its offer can be
/// bundled with the JOIN request and the WebRTC cold start (SSL init, peer connection factory,
/// audio device module) overlaps the TLS/WebSocket handshake instead of following it.
///
/// Deliberately not a stage payload: it is owned lexically by the connect sequence, which either
/// hands it to ``JoinDependencies/make(room:connection:joinResponse:rtcConfiguration:singlePeerConnection:earlyPublisher:)``
/// or closes it. So the stage invariant still holds — staged transports exist if and only if the
/// stage is `.connected`. Mirrors the `early_publisher_pc` local in rust-sdks' `RtcSession::connect`.
struct EarlyPublisher: Sendable {
    let transport: Transport
    let dataChannels: PublisherDataChannels

    /// The offer to bundle with the JOIN request, or `nil` when it could not be produced.
    /// Absent means "negotiate the ordinary way", never a failed connect.
    let offer: Livekit_SessionDescription?

    /// Builds the transport, its data channels, and the deferred initial offer.
    ///
    /// Only ever called for single PC mode, where the publisher is primary — so the
    /// configuration passed here carries the client-side settings only, and the server's ICE
    /// servers are installed later by `JoinDependencies.make`.
    static func make(room: Room, rtcConfiguration: LKRTCConfiguration) async throws -> EarlyPublisher {
        let transport = try await Transport(config: rtcConfiguration,
                                            target: .publisher,
                                            primary: true,
                                            singlePCMode: true,
                                            delegate: room)

        // Created before the offer so its `m=application` section is negotiated by the JOIN
        // exchange rather than costing a second one.
        let dataChannels = await PublisherDataChannels.make(on: transport)

        do {
            let initialOffer = try await transport.createInitialOffer()
            return EarlyPublisher(transport: transport,
                                  dataChannels: dataChannels,
                                  offer: initialOffer.map { $0.offer.toPBType(offerId: $0.offerId) })
        } catch {
            // A failed offer is recoverable: drop it and let the transport negotiate normally
            // once the JOIN response arrives.
            room.log("Failed to create the initial publisher offer, falling back to negotiation after JOIN: \(error)", .warning)
            await transport.clearPendingInitialOffer()
            return EarlyPublisher(transport: transport, dataChannels: dataChannels, offer: nil)
        }
    }

    func close() async {
        await transport.close()
    }
}

/// The publisher's three outbound data channels, created together so both the early and the
/// post-JOIN publisher paths negotiate the same layout.
struct PublisherDataChannels: Sendable {
    let reliable: LKRTCDataChannel?
    let lossy: LKRTCDataChannel?
    let dataTrack: LKRTCDataChannel?

    static func make(on transport: Transport) async -> PublisherDataChannels {
        // data over pub channel for backwards compatibility
        let reliable = await transport.dataChannel(for: LKRTCDataChannel.Labels.reliable,
                                                   configuration: RTC.createDataChannelConfiguration())

        let lossy = await transport.dataChannel(for: LKRTCDataChannel.Labels.lossy,
                                                configuration: RTC.createDataChannelConfiguration(ordered: false, maxRetransmits: 0))

        // Data track channel (unordered, unreliable — DTP handles its own sequencing).
        let dataTrack = await transport.dataChannel(for: LKRTCDataChannel.Labels.dataTrack,
                                                    configuration: RTC.createDataChannelConfiguration(ordered: false, maxRetransmits: 0))

        return PublisherDataChannels(reliable: reliable, lossy: lossy, dataTrack: dataTrack)
    }

    /// Hands the channels to the room's pairs and to the connection-scoped data track subsystem.
    func install(room: Room, connection: ConnectionDependencies) {
        room.publisherDataChannel.set(reliable: reliable)
        room.publisherDataChannel.set(lossy: lossy)
        if let dataTrack { connection.dataTracks.setPublisherChannel(dataTrack) }

        room.log("dataChannel.\(String(describing: reliable?.label)) : \(String(describing: reliable?.channelId))")
        room.log("dataChannel.\(String(describing: lossy?.label)) : \(String(describing: lossy?.channelId))")
        room.log("dataChannel.\(String(describing: dataTrack?.label)) : \(String(describing: dataTrack?.channelId))")
    }
}

// MARK: - Join dependencies

/// Subsystems scoped to one server JOIN: created from a JOIN response, retired on full reconnect
/// or disconnect, carried across a quick (resume) reconnect.
///
/// Constructible only through ``make(room:connection:joinResponse:rtcConfiguration:singlePeerConnection:)``
/// from its predecessor — a join without a connection cannot be represented, and a re-join re-runs
/// the factory by construction.
final class JoinDependencies: Sendable {
    /// The connection this join was established on. Join implies connection, by construction.
    let connection: ConnectionDependencies
    let transport: TransportMode

    private init(connection: ConnectionDependencies, transport: TransportMode) {
        self.connection = connection
        self.transport = transport
    }

    /// Builds the join-tier graph from a JOIN response: transports, their data channels, and the
    /// hand-off of the data track channel to the connection-scoped subsystem.
    /// - Parameter earlyPublisher: A publisher built before the socket opened, whose offer was
    ///   bundled with this JOIN. Adopted rather than rebuilt; the server's ICE servers are
    ///   installed onto it here, which is what releases its deferred initial offer for
    ///   application when the answer lands. Must be `nil` unless `singlePeerConnection`.
    static func make(room: Room,
                     connection: ConnectionDependencies,
                     joinResponse: Livekit_JoinResponse,
                     rtcConfiguration: LKRTCConfiguration,
                     singlePeerConnection: Bool,
                     earlyPublisher: EarlyPublisher? = nil) async throws -> JoinDependencies
    {
        let isSinglePC = singlePeerConnection
        let isSubscriberPrimary = isSinglePC ? false : joinResponse.subscriberPrimary
        room.log("subscriberPrimary: \(isSubscriberPrimary), singlePeerConnection: \(isSinglePC)")

        let publisher: Transport
        let dataChannels: PublisherDataChannels

        if let earlyPublisher {
            publisher = earlyPublisher.transport
            dataChannels = earlyPublisher.dataChannels
            // The early publisher only had the client-side configuration, so ICE gathering has
            // not started yet. This installs the server's ICE servers first.
            try await publisher.set(configuration: rtcConfiguration)
        } else {
            // Publisher always created; is primary in single PC mode
            publisher = try await Transport(config: rtcConfiguration,
                                            target: .publisher,
                                            primary: isSinglePC || !isSubscriberPrimary,
                                            singlePCMode: isSinglePC,
                                            delegate: room)
            dataChannels = await PublisherDataChannels.make(on: publisher)
        }

        await publisher.set { [weak room] offer, offerId in
            guard let room else { return }
            room.log("Publisher onOffer with offerId: \(offerId), sdp: \(offer.sdp)")
            try await room.signalClient.send(offer: offer, offerId: offerId)
            room.connectSpan?.record("offer_sent")
        }

        dataChannels.install(room: room, connection: connection)

        let subscriber: Transport? = if isSinglePC {
            nil
        } else {
            try await Transport(config: rtcConfiguration,
                                target: .subscriber,
                                primary: isSubscriberPrimary,
                                delegate: room)
        }

        let transport: TransportMode = if let subscriber, isSubscriberPrimary {
            .subscriberPrimary(publisher: publisher, subscriber: subscriber)
        } else if let subscriber {
            .publisherPrimary(publisher: publisher, subscriber: subscriber)
        } else {
            .publisherOnly(publisher: publisher)
        }

        room.log("[Connect] Fast publish enabled: \(joinResponse.fastPublish ? "true" : "false")")

        return JoinDependencies(connection: connection, transport: transport)
    }
}

extension JoinDependencies: Equatable {
    static func == (lhs: JoinDependencies, rhs: JoinDependencies) -> Bool { lhs === rhs }
}

// MARK: - Stage

/// The dependency plane of a ``Room``: which per-connection / per-join subsystems currently exist.
///
/// Stage payloads form an initializer chain (a join is constructible only from a connection), so
/// construction order across tiers is a compile-time property, and stage-gated storage replaces
/// optional fields: transports exist if and only if the stage is `.connected`.
///
/// Lives inside `Room.State`, so a stage transition and its data-tier reset are one atomic
/// mutation under the same lock.
enum DependencyStage: Equatable {
    case idle
    case connecting(ConnectionDependencies)
    case connected(JoinDependencies)
}

extension DependencyStage {
    var connection: ConnectionDependencies? {
        switch self {
        case .idle: nil
        case let .connecting(connection): connection
        case let .connected(join): join.connection
        }
    }

    var join: JoinDependencies? {
        if case let .connected(join) = self {
            join
        } else { nil }
    }

    // MARK: - Transitions (the only paths on which stage payloads are staged or retired)

    /// `connect()`: idle → connecting. Throws if a previous session is still staged —
    /// `cleanUp()` must have retired it first.
    mutating func begin(_ connection: ConnectionDependencies) throws {
        guard case .idle = self else {
            throw LiveKitError(.invalidState, message: "Cannot begin a connection while one is staged")
        }
        self = .connecting(connection)
    }

    /// JOIN response applied: connecting → connected. Throws on a duplicate JOIN or a join built
    /// against a retired connection.
    mutating func join(_ join: JoinDependencies) throws {
        guard case let .connecting(connection) = self, join.connection === connection else {
            throw LiveKitError(.invalidState, message: "JOIN is only valid for the currently connecting connection")
        }
        self = .connected(join)
    }

    /// Full reconnect (and the join half of a disconnect): retires the join, keeps the connection.
    /// The caller owns closing the returned join's resources — detach, then destroy.
    mutating func retireJoin() -> JoinDependencies? {
        guard case let .connected(join) = self else { return nil }
        self = .connecting(join.connection)
        return join
    }

    /// Disconnect: retires everything. The join is expected to have been retired and closed
    /// already (`cleanUpRTC`); it is returned here so no path can drop one silently.
    mutating func end() -> (join: JoinDependencies?, connection: ConnectionDependencies?) {
        let join = retireJoin()
        guard case let .connecting(connection) = self else { return (join, nil) }
        self = .idle
        return (join, connection)
    }
}
