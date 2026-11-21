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
import Foundation

/// The offer and matching track requests serialized into one JOIN request.
struct InitialPublish: Sendable {
    let offer: Livekit_SessionDescription
    let requests: [Livekit_AddTrackRequest]
}

/// A publisher peer connection built *before* the signal socket opens, so its offer can be
/// bundled with the JOIN request and the server answers it in the same exchange, removing the
/// offer→answer round trip from the connect path.
///
/// The WebRTC cold start (SSL init, peer connection factory, audio device module) is *not*
/// overlapped with the TLS/WebSocket handshake: `make` is awaited to completion before
/// `signalClient.connect`, because the offer has to be in the JOIN URL. It is serialized ahead
/// of the handshake, so the measured win is the saved round trip alone. rust-sdks orders it the
/// same way in `RtcSession::connect`.
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
    let preparedTracks: [LocalParticipant.PreparedPublish]
    let preparedAudio: PreparedAudioPublication?
    let audioRequest: Livekit_AddTrackRequest?

    /// Builds the transport, its data channels, and the deferred initial offer.
    ///
    /// Only ever called for single PC mode, where the publisher is primary — so the
    /// configuration passed here carries the client-side settings only, and the server's ICE
    /// servers are installed later by `JoinDependencies.make`.
    static func make(room: Room, rtcConfiguration: LKRTCConfiguration, publishTracks: [InitialTrack] = [], preparedAudio: PreparedAudioPublication? = nil) async throws -> EarlyPublisher {
        let transport = try await Transport(config: rtcConfiguration,
                                            target: .publisher,
                                            primary: true,
                                            singlePCMode: true,
                                            delegate: room)

        // Created before the offer so its `m=application` section is negotiated by the JOIN
        // exchange rather than costing a second one.
        let dataChannels = await PublisherDataChannels.make(on: transport)

        var preparedTracks: [LocalParticipant.PreparedPublish] = []
        do {
            for initial in publishTracks {
                let prepared = try await room.localParticipant.preparePublish(track: initial.track, options: initial.options, validateCodecs: false)
                preparedTracks.append(prepared)
                try await room.localParticipant.configureSender(prepared, publisher: transport)
            }
        } catch {
            await transport.close()
            await preparedAudio?.discard(on: transport)
            for prepared in preparedTracks where prepared.track._state.transport === transport {
                await prepared.track.set(transport: nil, rtpSender: nil)
            }
            throw error
        }

        do {
            let audioRequest = try await preparedAudio?.reserve(on: transport)
            guard let initialOffer = try await transport.createInitialOffer() else {
                throw LiveKitError(.invalidState, message: "Initial offer was not created")
            }
            return EarlyPublisher(transport: transport,
                                  dataChannels: dataChannels,
                                  offer: initialOffer.offer.toPBType(offerId: initialOffer.offerId),
                                  preparedTracks: preparedTracks, preparedAudio: preparedAudio, audioRequest: audioRequest)
        } catch {
            // A failed offer is recoverable: drop it and let the transport negotiate normally
            // once the JOIN response arrives.
            room.log("Failed to create the initial publisher offer, falling back to negotiation after JOIN: \(error)", .warning)
            await transport.close()
            await preparedAudio?.discard(on: transport)
            for prepared in preparedTracks where prepared.track._state.transport === transport {
                await prepared.track.set(transport: nil, rtpSender: nil)
            }
            if error is CancellationError { throw error }
            let fallback = try await Transport(config: rtcConfiguration, target: .publisher,
                                               primary: true, singlePCMode: true, delegate: room)
            let fallbackChannels = await PublisherDataChannels.make(on: fallback)
            return EarlyPublisher(transport: fallback, dataChannels: fallbackChannels, offer: nil, preparedTracks: [], preparedAudio: nil, audioRequest: nil)
        }
    }

    func detachTracks() async {
        for prepared in preparedTracks where prepared.track._state.transport === transport {
            await prepared.track.set(transport: nil, rtpSender: nil)
        }
    }

    func close() async {
        await transport.close()
        await preparedAudio?.discard(on: transport)
        await detachTracks()
    }
}
