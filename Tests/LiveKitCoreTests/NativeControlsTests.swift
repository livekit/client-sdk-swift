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

import CoreVideo
import Foundation
@testable import LiveKit
import Testing

extension NativeRoomTests {
    /// Core sends DTMF without data E2EE, so an encrypted room must not reject it. The public Swift
    /// API has no DTMF receive callback, so this checks the send path only.
    @Test
    func encryptedRoomPublishesDtmf() async throws {
        let encryption = EncryptionOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: "native-swift-dtmf-test-key"))
        let room = Room(roomOptions: RoomOptions(encryptionOptions: encryption))
        do {
            try await room.connect(url: url, token: token("dtmf", room: "swift-dtmf-\(UUID().uuidString)"))
            try await room.localParticipant.publishDtmf(code: 10, digit: "*")
            try await room.localParticipant.publishDtmf(code: 1, digit: "1")
        } catch {
            await room.disconnect()
            throw error
        }
        await room.disconnect()
        await #expect(throws: LiveKitError.self) { try await room.localParticipant.publishDtmf(code: 11, digit: "#") }
    }

    /// Permissions gate subscription and follow the public precedence rules. The deny check only
    /// observes that no track arrives within one second.
    @Test @MainActor
    func subscriptionPermissionsAndVideoQuality() async throws {
        let name = "swift-controls-\(UUID().uuidString)"
        let sender = Room()
        let receiver = Room(roomOptions: RoomOptions(adaptiveStream: false))
        let track = await LocalVideoTrack.createBufferTrack(options: .init(dimensions: Dimensions(width: 320, height: 240)))
        let capturer = try #require(track.capturer as? BufferCapturer)
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess)
        let pixels = try #require(pixelBuffer)
        let producer = Task { @MainActor in
            while !Task.isCancelled {
                capturer.capture(pixels)
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
        defer { producer.cancel() }
        do {
            let permissions = sender.localParticipant
            try await sender.connect(url: url, token: token("sender", room: name))
            try await permissions.setTrackSubscriptionPermissions(allParticipantsAllowed: false)
            try await receiver.connect(url: url, token: token("receiver", room: name))
            try await eventually { sender.remoteParticipants[Participant.Identity(from: "receiver")]?.sid != nil }
            let receiverSid = try #require(sender.remoteParticipants[Participant.Identity(from: "receiver")]?.sid?.stringValue)
            // An SID the sender does not know is skipped, so the receiver stays denied.
            try await permissions.setTrackSubscriptionPermissions(allParticipantsAllowed: false, trackPermissions: [
                ParticipantTrackPermission(participantSid: "PA_unknown", allTracksAllowed: true),
            ])
            // An invalid track SID that applies is rejected before anything changes.
            await #expect(throws: LiveKitError.self) {
                try await permissions.setTrackSubscriptionPermissions(allParticipantsAllowed: false, trackPermissions: [
                    ParticipantTrackPermission(participantSid: receiverSid, allTracksAllowed: false, allowedTrackSids: ["invalid"]),
                ])
            }
            try await permissions.publish(videoTrack: track)
            try await eventually { receiver.remoteParticipants.values.first?.videoTracks.first != nil }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            #expect(receiver.remoteParticipants.values.first?.videoTracks.first?.track == nil)

            // allTracksAllowed takes precedence, so its invalid track SID is ignored.
            try await permissions.setTrackSubscriptionPermissions(allParticipantsAllowed: false, trackPermissions: [
                ParticipantTrackPermission(participantSid: receiverSid, allTracksAllowed: true, allowedTrackSids: ["invalid"]),
            ])
            try await eventually { receiver.remoteParticipants.values.first?.videoTracks.first?.track != nil }
            // allParticipantsAllowed takes precedence, so a participant entry with an invalid SID is ignored.
            try await permissions.setTrackSubscriptionPermissions(allParticipantsAllowed: true, trackPermissions: [
                ParticipantTrackPermission(participantSid: receiverSid, allTracksAllowed: false, allowedTrackSids: ["invalid"]),
            ])

            try await checkQualityRequests(sender: sender, receiver: receiver)

            await sender.disconnect()
            await receiver.disconnect()
        } catch {
            await sender.disconnect()
            await receiver.disconnect()
            throw error
        }
    }

    /// A quality request is accepted, which does not prove the layer the server selects.
    @MainActor
    private func checkQualityRequests(sender: Room, receiver: Room) async throws {
        let remote = try #require(receiver.remoteParticipants.values.first?.videoTracks.first as? RemoteTrackPublication)
        try await remote.set(videoQuality: .medium)
        #expect(remote._state.trackSettings.videoQuality == .medium)
        await #expect(throws: LiveKitError.self) { try await remote.set(preferredFPS: 15) }

        // A failed native request keeps the previous local value, so a later request is not skipped.
        let closedRoom = Room()
        try await closedRoom.connect(url: url, token: token("closed", room: "swift-closed-\(UUID().uuidString)"))
        let closed = closedRoom.nativeSession.copy()
        await closedRoom.disconnect()
        let live = receiver.nativeSession.copy()
        receiver.nativeSession.mutate { $0 = closed }
        await #expect(throws: LiveKitError.self) { try await remote.set(videoQuality: .high) }
        receiver.nativeSession.mutate { $0 = live }
        #expect(remote._state.trackSettings.videoQuality == .medium)
        try await remote.set(videoQuality: .high)
        #expect(remote._state.trackSettings.videoQuality == .high)

        // The native command is video-only and rejects audio, so success shows audio never reaches it.
        let audio = await LocalAudioTrack.createTrack(reportStatistics: false)
        let source = try await sender.requireNativeSession().createAudioTrack(name: audio.name, channels: 1)
        audio.nativeAudio.mutate { $0 = source }
        try await sender.localParticipant.publish(audioTrack: audio)
        try await eventually { receiver.remoteParticipants.values.first?.audioTracks.first?.track != nil }
        let remoteAudio = try #require(receiver.remoteParticipants.values.first?.audioTracks.first as? RemoteTrackPublication)
        try await remoteAudio.set(videoQuality: .high)
        #expect(remoteAudio._state.trackSettings.videoQuality == .high)
    }
}
