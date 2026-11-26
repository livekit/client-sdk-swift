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

import AVFoundation
import Foundation
@testable import LiveKit
import LiveKitFFI
import Testing

extension NativeRoomTests {
    @Test(arguments: [false, true])
    func encryptedNativeAudioPublication(microphone: Bool) async throws {
        let name = "swift-media-\(UUID().uuidString)"
        let encryption = EncryptionOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: "native-swift-media-test-key"))
        let options = RoomOptions(encryptionOptions: encryption, reportRemoteTrackStatistics: true)
        let sender = Room(roomOptions: options)
        let subscriptionOrder = InitialSubscriptionWatcher()
        let receiver = Room(delegate: subscriptionOrder, roomOptions: options)
        do {
            try await sender.connect(url: url, token: token("sender", room: name))
            let (local, source) = try await publishAudio(sender, microphone: microphone)
            let track = try #require(local.track as? LocalAudioTrack)
            #expect(local.encryptionType == .gcm)
            try await receiver.connect(url: url, token: token("receiver", room: name))
            try await eventually { receiver.remoteParticipants.values.first?.audioTracks.first?.track != nil }
            let remote = try #require(receiver.remoteParticipants.values.first?.audioTracks.first)
            let remoteTrack = try #require(remote.track as? RemoteAudioTrack)
            try await eventually { subscriptionOrder.events.copy().contains("subscribed") }
            #expect(subscriptionOrder.events.copy().prefix(2) == ["connected", "subscribed"])
            let rendered = PCMWatcher()
            remoteTrack.add(audioRenderer: rendered)
            let samples = (0 ..< 480).map { Int16(sin(Double($0) * 2 * .pi * 440 / 48000) * 12000) }
            for _ in 0 ..< 100 {
                try await source?.captureFrame(frame: .init(samples: samples, sampleRate: 48000, numChannels: 1, samplesPerChannel: 480))
                if rendered.peak.copy() > 0 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try await eventually { rendered.peak.copy() > 0 }
            try await checkNativeStatistics(local: track, remote: remoteTrack)
            #expect(remote.encryptionType == .gcm)
            try await checkStreams(sender: sender, receiver: receiver, encryption: .gcm)
            try await receiver.registerRpcMethod("encrypted-echo") { $0.payload }
            #expect(try await sender.localParticipant.performRpc(destinationIdentity: .init(from: "receiver"), method: "encrypted-echo", payload: "encrypted") == "encrypted")
            try await local.mute()
            try await eventually { remote.isMuted }
            #expect(receiver.remoteParticipants.values.first?.audioTracks.first === remote)
            #expect(remote.track === remoteTrack)
            try await local.unmute()
            try await eventually { !remote.isMuted }
            let subscription = try #require(remote as? RemoteTrackPublication)
            try await subscription.set(subscribed: false)
            try await eventually { remote.track == nil }
            try await sender.localParticipant.unpublish(publication: local)
            try await eventually { receiver.remoteParticipants.values.first?.audioTracks.isEmpty == true }
            #expect(track.publishState == .unpublished)
            await sender.disconnect()
            await receiver.disconnect()
        } catch {
            await sender.disconnect()
            await receiver.disconnect()
            throw error
        }
    }

    private func publishAudio(_ sender: Room, microphone: Bool) async throws -> (LocalTrackPublication, NativeLocalAudioTrack?) {
        if microphone { return try (#require(try await sender.localParticipant.setMicrophone(enabled: true)), nil) }
        let track = await LocalAudioTrack.createTrack(reportStatistics: true)
        let source = try await sender.requireNativeRoom().createAudioTrack(name: track.name, channels: 1)
        track.nativeAudio.mutate { $0 = source }
        let publication = try await sender.localParticipant.publish(audioTrack: track)
        #expect(publication.track === track)
        return (publication, source)
    }

    @Test @MainActor
    func encryptedBufferVideoRenders() async throws {
        let name = "swift-video-\(UUID().uuidString)"
        let encryption = EncryptionOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: "native-swift-video-test-key"))
        let options = RoomOptions(encryptionOptions: encryption, reportRemoteTrackStatistics: true)
        let sender = Room(roomOptions: options)
        let receiver = Room(roomOptions: options)
        let track = await LocalVideoTrack.createBufferTrack(options: .init(dimensions: Dimensions(width: 320, height: 240)), reportStatistics: true)
        let capturer = try #require(track.capturer as? BufferCapturer)
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess)
        let pixels = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) { memset(base, 127, CVPixelBufferGetBytesPerRow(pixels) * 240) }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let producer = Task { @MainActor in
            while !Task.isCancelled {
                capturer.capture(pixels)
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
        defer { producer.cancel() }
        do {
            try await sender.connect(url: url, token: token("sender", room: name))
            try await receiver.connect(url: url, token: token("receiver", room: name))
            let publication = try await sender.localParticipant.publish(videoTrack: track, options: .init(simulcast: false))
            #expect(publication.encryptionType == .gcm)
            try await eventually { receiver.remoteParticipants.values.first?.videoTracks.first?.track != nil }
            let remote = try #require(receiver.remoteParticipants.values.first?.videoTracks.first?.track as? RemoteVideoTrack)
            let view = VideoView()
            view.track = remote
            try await eventually { remote.videoFrame != nil && view.isRendering }
            try await checkNativeStatistics(local: track, remote: remote)
            #expect(remote.dimensions == Dimensions(width: 320, height: 240))
            producer.cancel()
            await producer.value
            await sender.disconnect()
            #expect(track.nativeVideo.copy() == nil)
            #expect(track.nativeCapture.copy() == nil)
            #expect(track.capturer.captureState == .stopped)
            try await eventually { receiver.remoteParticipants.isEmpty }
            view.track = nil
            await receiver.disconnect()
        } catch {
            await sender.disconnect()
            await receiver.disconnect()
            throw error
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVEKIT_TESTING_CAMERA"] == "1")) @MainActor
    func encryptedCameraRenders() async throws {
        let name = "swift-camera-\(UUID().uuidString)"
        let encryption = EncryptionOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: "native-swift-camera-test-key"))
        let options = RoomOptions(encryptionOptions: encryption, reportRemoteTrackStatistics: true)
        let sender = Room(roomOptions: options)
        let receiver = Room(roomOptions: options)
        do {
            try await sender.connect(url: url, token: token("sender", room: name))
            try await receiver.connect(url: url, token: token("receiver", room: name))
            let publication = try #require(try await sender.localParticipant.setCamera(enabled: true, captureOptions: .init(deviceType: .builtInWideAngleCamera)))
            #expect(publication.encryptionType == .gcm)
            try await eventually { receiver.remoteParticipants.values.first?.videoTracks.first?.track != nil }
            let remote = try #require(receiver.remoteParticipants.values.first?.videoTracks.first?.track as? RemoteVideoTrack)
            let view = VideoView()
            view.track = remote
            try await eventually { view.isRendering }
            #expect(remote.videoFrame != nil)
            try await sender.localParticipant.unpublish(publication: publication)
            view.track = nil
            await sender.disconnect()
            await receiver.disconnect()
        } catch {
            await sender.disconnect()
            await receiver.disconnect()
            throw error
        }
    }

    private func checkNativeStatistics(local: LiveKit.Track, remote: LiveKit.Track) async throws {
        try await eventually {
            (local.statistics?.outboundRtpStream.first?.bytesSent ?? 0) > 0 &&
                (remote.statistics?.inboundRtpStream.first?.bytesReceived ?? 0) > 0
        }
        let native = try #require(local.nativePublication.copy())
        let records = try await native.getStatistics()
        guard let value = records.compactMap({ record in
            if case let .outboundRtp(value)? = record.stats { return value }
            return nil
        }).first else { Issue.record("Native outbound statistics missing"); return }
        var large = value
        large.sent.bytesSent = 9_007_199_254_740_993
        let mapped = TrackStatistics(native: [.init(stats: .outboundRtp(large))], previous: nil)
        #expect(mapped.outboundRtpStream.first?.bytesSent == 9_007_199_254_740_993)
        #expect(mapped.outboundRtpStream.first?.id == value.rtc.id)
        #expect(mapped.outboundRtpStream.first?.codecId == value.stream.codecId)
        #expect(mapped.outboundRtpStream.first?.ssrc == UInt(value.stream.ssrc))
    }

    private final class InitialSubscriptionWatcher: NSObject, RoomDelegate, Sendable {
        let events = StateSync<[String]>([])
        func room(_: Room, didUpdateConnectionState state: LiveKit.ConnectionState, from _: LiveKit.ConnectionState) {
            if state == .connected { events.mutate { $0.append("connected") } }
        }

        func room(_ room: Room, participant _: RemoteParticipant, didSubscribeTrack _: RemoteTrackPublication) {
            #expect(room.connectionState == .connected)
            events.mutate { $0.append("subscribed") }
        }
    }

    private final class PCMWatcher: AudioRenderer {
        let peak = StateSync<Int>(0)
        func render(pcmBuffer: AVAudioPCMBuffer) {
            guard let samples = pcmBuffer.int16ChannelData?[0] else { return }
            let value = (0 ..< Int(pcmBuffer.frameLength)).map { abs(Int(samples[$0])) }.max() ?? 0
            peak.mutate { $0 = max($0, value) }
        }
    }
}
