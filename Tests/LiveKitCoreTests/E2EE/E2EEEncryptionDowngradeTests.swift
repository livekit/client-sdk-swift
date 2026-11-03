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

        init() throws {
            room = Room()
            let options = RoomOptions(encryptionOptions: EncryptionOptions(keyProvider: BaseKeyProvider()))
            let dependencies = ConnectionDependencies(idle: room._state.stage.idle, room: room, roomOptions: options)
            try room._state.mutate { try $0.stage.begin(dependencies) }
            manager = try #require(room.e2eeManager)
        }

        @discardableResult
        func update(tracks: [Livekit_TrackInfo]) -> RemoteParticipant {
            let info = Livekit_ParticipantInfo.with {
                $0.sid = "PA_remote"
                $0.identity = identity.stringValue
                $0.tracks = tracks
            }
            return room._state.mutate {
                let participant = $0.updateRemoteParticipant(info: info, room: room)
                participant.set(info: info, connectionState: $0.connectionState)
                return participant
            }
        }

        func publication(_ sid: String, of participant: RemoteParticipant) throws -> RemoteTrackPublication {
            try #require(participant.trackPublications[Track.Sid(from: sid)] as? RemoteTrackPublication)
        }

        @RTC
        func attachedCryptorEnabled(for publication: RemoteTrackPublication) async throws -> Bool? {
            let pc = try #require(RTC.createPeerConnection(.liveKitDefault(), constraints: .defaultPCConstraints))
            defer {
                manager.cleanUp()
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
                #expect(cryptor.map { state.trackPublications[$0] === publication } ?? true)
                return cryptor?.enabled
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
        let context = try Context()
        context.manager.enableE2EE(enabled: enabled)
        let participant = context.update(tracks: [Self.track("TR_encrypted", encryption: .gcm)])
        let original = try context.publication("TR_encrypted", of: participant)
        try await participant.unpublish(publication: original, notify: false)
        context.update(tracks: [Self.track("TR_republished", encryption: .none)])
        let republished = try context.publication("TR_republished", of: participant)

        #expect(republished.encryptionType == .none)
        #expect(try await context.attachedCryptorEnabled(for: republished) == enabled)
    }

    @Test
    func extraNoneTrackUsesCryptor() async throws {
        let context = try Context()
        let participant = context.update(tracks: [
            Self.track("TR_encrypted", encryption: .gcm),
            Self.track("TR_extra", encryption: .none),
        ])
        let extra = try context.publication("TR_extra", of: participant)

        #expect(try await context.attachedCryptorEnabled(for: extra) == true)
    }

    @Test
    func neverEncryptedParticipantHasNoCryptor() async throws {
        let context = try Context()
        let participant = context.update(tracks: [Self.track("TR_plaintext", encryption: .none)])
        let plaintext = try context.publication("TR_plaintext", of: participant)

        #expect(try await context.attachedCryptorEnabled(for: plaintext) == nil)
    }

    @Test
    func latchSurvivesUnpublish() async throws {
        let context = try Context()
        let participant = context.update(tracks: [Self.track("TR_encrypted", encryption: .gcm)])
        await participant.unpublishAll(notify: false)
        #expect(participant.trackPublications.isEmpty)
        context.update(tracks: [Self.track("TR_plaintext", encryption: .none)])
        let plaintext = try context.publication("TR_plaintext", of: participant)

        #expect(try await context.attachedCryptorEnabled(for: plaintext) == true)
    }

    @Test
    func latchSurvivesFullReconnectAndParticipantDeparture() async throws {
        let context = try Context()
        let participant = context.update(tracks: [Self.track("TR_encrypted", encryption: .gcm)])
        await participant.unpublishAll(notify: false)
        context.room._state.mutate { $0.remoteParticipants.removeAll() }
        context.manager.cleanUp(isFullReconnect: true)
        let rejoined = context.update(tracks: [Self.track("TR_plaintext", encryption: .none)])
        let plaintext = try context.publication("TR_plaintext", of: rejoined)

        #expect(rejoined !== participant)
        #expect(try await context.attachedCryptorEnabled(for: plaintext) == true)
    }

    @Test
    func laterUnsubscribedEncryptedTrackLatchesParticipant() async throws {
        let context = try Context()
        let participant = context.update(tracks: [Self.track("TR_plaintext", encryption: .none)])
        context.update(tracks: [
            Self.track("TR_plaintext", encryption: .none),
            Self.track("TR_encrypted", encryption: .gcm),
        ])
        let encrypted = try context.publication("TR_encrypted", of: participant)
        let plaintext = try context.publication("TR_plaintext", of: participant)

        #expect(encrypted.track == nil)
        #expect(try await context.attachedCryptorEnabled(for: plaintext) == true)
    }
}
