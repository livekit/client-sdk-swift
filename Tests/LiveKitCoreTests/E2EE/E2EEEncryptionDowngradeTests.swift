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

@testable import LiveKit
import LiveKitWebRTC
import Testing

@Suite(.tags(.e2ee))
struct E2EEEncryptionDowngradeTests {
    private struct Context {
        let room: Room
        let manager: E2EEManager
        let identity = Participant.Identity(from: "remote")

        init(tracks: [Livekit_TrackInfo]) async throws {
            room = Room()
            let options = RoomOptions(encryptionOptions: EncryptionOptions(keyProvider: BaseKeyProvider()))
            let dependencies = ConnectionDependencies(idle: room._state.stage.idle, room: room, roomOptions: options)
            try room._state.mutate { try $0.stage.begin(dependencies) }
            manager = try #require(room.e2eeManager)
            let join = Livekit_JoinResponse.with {
                $0.otherParticipants = [info(tracks: tracks)]
            }
            await room.signalClient(room.signalClient, didReceiveConnectResponse: .join(join))
        }

        func info(tracks: [Livekit_TrackInfo]) -> Livekit_ParticipantInfo {
            Livekit_ParticipantInfo.with {
                $0.sid = "PA_remote"
                $0.identity = identity.stringValue
                $0.tracks = tracks
            }
        }

        func participant() throws -> RemoteParticipant {
            try #require(room.remoteParticipants[identity])
        }

        func publication(_ sid: String, of participant: RemoteParticipant) throws -> RemoteTrackPublication {
            try #require(participant.trackPublications[Track.Sid(from: sid)] as? RemoteTrackPublication)
        }

        @RTC
        func attachedCryptorState(for publication: RemoteTrackPublication) async throws -> (enabled: Bool?, publication: TrackPublication?) {
            let pc = try #require(RTC.createPeerConnection(.liveKitDefault(), constraints: .defaultPCConstraints))
            defer {
                manager.cleanUp(isFullReconnect: true)
                nonisolated(unsafe) let pc = pc
                RTC.park { pc.close() }
            }
            let receiver = try #require(pc.addTransceiver(of: .video)?.receiver)
            let mediaTrack = try #require(receiver.track)
            let track = RemoteVideoTrack(name: publication.name,
                                         source: publication.source,
                                         track: RTCMediaTrack(mediaTrack),
                                         reportStatistics: false)
            await track.set(transport: nil, rtpReceiver: RTCReceiver(receiver))
            await publication.set(track: track)
            await manager.addRtpReceiver(publication: publication, participantIdentity: identity)
            return manager._state.read { state in
                let cryptor = state.frameCryptors[[identity: publication.sid]]
                return (cryptor?.enabled, cryptor.flatMap { state.trackPublications[$0] })
            }
        }
    }

    private static func track(_ sid: String, encryption: Livekit_Encryption.TypeEnum) -> Livekit_TrackInfo {
        Livekit_TrackInfo.with {
            $0.sid = sid
            $0.type = .video
            $0.source = .camera
            $0.encryption = encryption
        }
    }

    @Test(arguments: [true, false])
    func republishedNoneUsesCryptor(enabled: Bool) async throws {
        let context = try await Context(tracks: [Self.track("TR_encrypted", encryption: .gcm)])
        context.manager.enableE2EE(enabled: enabled)
        let participant = try context.participant()
        let original = try context.publication("TR_encrypted", of: participant)
        try await participant.unpublish(publication: original, notify: false)
        await context.room.signalClient(context.room.signalClient, didUpdateParticipants: [
            context.info(tracks: [Self.track("TR_republished", encryption: .none)]),
        ])
        let republished = try context.publication("TR_republished", of: participant)
        let cryptor = try await context.attachedCryptorState(for: republished)

        #expect(republished.encryptionType == .none)
        #expect(cryptor.enabled == enabled)
        #expect(cryptor.publication === republished)
    }

    @Test
    func extraNoneTrackUsesCryptor() async throws {
        let context = try await Context(tracks: [Self.track("TR_encrypted", encryption: .gcm)])
        let participant = try context.participant()
        await context.room.signalClient(context.room.signalClient, didUpdateParticipants: [
            context.info(tracks: [
                Self.track("TR_encrypted", encryption: .gcm),
                Self.track("TR_extra", encryption: .none),
            ]),
        ])
        let extra = try context.publication("TR_extra", of: participant)
        let cryptor = try await context.attachedCryptorState(for: extra)

        #expect(cryptor.enabled == true)
        #expect(cryptor.publication === extra)
    }

    @Test
    func neverEncryptedParticipantHasNoCryptor() async throws {
        let context = try await Context(tracks: [Self.track("TR_plaintext", encryption: .none)])
        let participant = try context.participant()
        let plaintext = try context.publication("TR_plaintext", of: participant)
        let cryptor = try await context.attachedCryptorState(for: plaintext)

        #expect(cryptor.enabled == nil)
        #expect(cryptor.publication == nil)
    }

    @Test
    func latchSurvivesUnpublish() async throws {
        let context = try await Context(tracks: [Self.track("TR_encrypted", encryption: .gcm)])
        let participant = try context.participant()
        await participant.unpublishAll(notify: false)
        #expect(participant.trackPublications.isEmpty)
        await context.room.signalClient(context.room.signalClient, didUpdateParticipants: [
            context.info(tracks: [Self.track("TR_plaintext", encryption: .none)]),
        ])
        let plaintext = try context.publication("TR_plaintext", of: participant)
        let cryptor = try await context.attachedCryptorState(for: plaintext)

        #expect(cryptor.enabled == true)
        #expect(cryptor.publication === plaintext)
    }

    @Test
    func latchSurvivesFullReconnectAndParticipantDeparture() async throws {
        let context = try await Context(tracks: [Self.track("TR_encrypted", encryption: .gcm)])
        let participant = try context.participant()
        let departed = Livekit_ParticipantInfo.with {
            $0.sid = "PA_remote"
            $0.identity = context.identity.stringValue
            $0.state = .disconnected
        }
        await context.room.signalClient(context.room.signalClient, didUpdateParticipants: [departed])
        #expect(context.room.remoteParticipants.isEmpty)
        context.manager.cleanUp(isFullReconnect: true)
        await context.room.signalClient(context.room.signalClient, didUpdateParticipants: [
            context.info(tracks: [Self.track("TR_plaintext", encryption: .none)]),
        ])
        let rejoined = try context.participant()
        let plaintext = try context.publication("TR_plaintext", of: rejoined)
        let cryptor = try await context.attachedCryptorState(for: plaintext)

        #expect(rejoined !== participant)
        #expect(cryptor.enabled == true)
        #expect(cryptor.publication === plaintext)
    }

    @Test
    func laterUnsubscribedEncryptedTrackLatchesParticipant() async throws {
        let context = try await Context(tracks: [Self.track("TR_plaintext", encryption: .none)])
        let participant = try context.participant()
        await context.room.signalClient(context.room.signalClient, didUpdateParticipants: [
            context.info(tracks: [
                Self.track("TR_plaintext", encryption: .none),
                Self.track("TR_encrypted", encryption: .gcm),
            ]),
        ])
        let encrypted = try context.publication("TR_encrypted", of: participant)
        let plaintext = try context.publication("TR_plaintext", of: participant)
        let cryptor = try await context.attachedCryptorState(for: plaintext)

        #expect(encrypted.track == nil)
        #expect(cryptor.enabled == true)
        #expect(cryptor.publication === plaintext)
    }
}
