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

    /// Span factory for this connection, bound to the Room's telemetry session when telemetry is on.
    let tracer: TelemetryTracer

    init(room: Room, roomOptions: RoomOptions, tracer: TelemetryTracer = .detached) {
        dataTracks = DataTracks(room: room)
        self.tracer = tracer
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
        // The connection ended: ship what is queued. The session stays with the Room.
        Task { await Telemetry.shared.flush() }
    }
}

extension ConnectionDependencies: Equatable {
    static func == (lhs: ConnectionDependencies, rhs: ConnectionDependencies) -> Bool { lhs === rhs }
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
    static func make(room: Room,
                     connection: ConnectionDependencies,
                     joinResponse: Livekit_JoinResponse,
                     rtcConfiguration: LKRTCConfiguration,
                     singlePeerConnection: Bool) async throws -> JoinDependencies
    {
        let isSinglePC = singlePeerConnection
        let isSubscriberPrimary = isSinglePC ? false : joinResponse.subscriberPrimary
        room.log("subscriberPrimary: \(isSubscriberPrimary), singlePeerConnection: \(isSinglePC)")

        // Publisher always created; is primary in single PC mode
        let publisher = try Transport(config: rtcConfiguration,
                                      target: .publisher,
                                      primary: isSinglePC || !isSubscriberPrimary,
                                      singlePCMode: isSinglePC,
                                      delegate: room)

        await publisher.set { [weak room] offer, offerId in
            guard let room else { return }
            room.log("Publisher onOffer with offerId: \(offerId), sdp: \(offer.sdp)")
            try await room.signalClient.send(offer: offer, offerId: offerId)
            room.connectSpan?.record("offer_sent")
        }

        // data over pub channel for backwards compatibility

        let reliableDataChannel = await publisher.dataChannel(for: LKRTCDataChannel.Labels.reliable,
                                                              configuration: RTC.createDataChannelConfiguration())

        let lossyDataChannel = await publisher.dataChannel(for: LKRTCDataChannel.Labels.lossy,
                                                           configuration: RTC.createDataChannelConfiguration(ordered: false, maxRetransmits: 0))

        room.publisherDataChannel.set(reliable: reliableDataChannel)
        room.publisherDataChannel.set(lossy: lossyDataChannel)

        // Data track channel (unordered, unreliable — DTP handles its own sequencing).
        let dataTrackChannel = await publisher.dataChannel(for: LKRTCDataChannel.Labels.dataTrack,
                                                           configuration: RTC.createDataChannelConfiguration(ordered: false, maxRetransmits: 0))
        if let dataTrackChannel { connection.dataTracks.setPublisherChannel(dataTrackChannel) }

        room.log("dataChannel.\(String(describing: reliableDataChannel?.label)) : \(String(describing: reliableDataChannel?.channelId))")
        room.log("dataChannel.\(String(describing: lossyDataChannel?.label)) : \(String(describing: lossyDataChannel?.channelId))")
        room.log("dataChannel.\(String(describing: dataTrackChannel?.label)) : \(String(describing: dataTrackChannel?.channelId))")

        let subscriber = isSinglePC ? nil : try Transport(config: rtcConfiguration,
                                                          target: .subscriber,
                                                          primary: isSubscriberPrimary,
                                                          delegate: room)

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
