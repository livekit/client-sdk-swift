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

import AVFAudio
import Foundation
@testable import LiveKit
import LiveKitTestSupport
import Testing

/// Opt-in sequencing A/B: actual Session startup versus the previous capture/connect ordering.
@Suite(.serialized, .tags(.e2e))
struct SessionStartupLatencyTests {
    struct Sample: Codable {
        let concurrent: Bool
        let preConnectAudio: Bool
        let captureDelayMs: Int
        let repetition: Int
        let connectedMs: Double
        let publishedMs: Double
        let firstAudioMs: Double
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVEKIT_SESSION_BENCHMARK"] == "1"))
    @MainActor func compareStartup() async throws {
        var samples: [Sample] = []
        let repetitions = Int(ProcessInfo.processInfo.environment["LIVEKIT_SESSION_REPETITIONS"] ?? "10") ?? 10
        try await SessionTestAudioSource.withAudio {
            for delay in [0, 1000] {
                for buffering in [false, true] {
                    // One excluded warmup pair, then alternating A/B order. No sample retries.
                    for repetition in -1 ..< repetitions {
                        for concurrent in repetition.isMultiple(of: 2) ? [false, true] : [true, false] {
                            let sample = try await Self.measure(concurrent: concurrent, buffering: buffering,
                                                                delay: delay, repetition: repetition)
                            if repetition >= 0 { samples.append(sample) }
                        }
                    }
                }
            }
        }
        let output = ProcessInfo.processInfo.environment["LIVEKIT_SESSION_OUTPUT"] ?? "/tmp/swift-session-latency.json"
        try JSONEncoder().encode(samples).write(to: URL(fileURLWithPath: output))
        print("Session latency samples: \(output), count: \(samples.count)")
    }

    @MainActor private static func measure(concurrent: Bool, buffering: Bool, delay: Int, repetition: Int) async throws -> Sample {
        let name = "session-latency-\(UUID().uuidString)"
        let room = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        let peer = Room(roomOptions: RoomOptions(singlePeerConnection: true))
        let observer = StartupLatencyObserver()
        room.add(delegate: observer)
        peer.add(delegate: observer)
        let url = TestEnvironment.liveKitServerUrl()
        let token = try TestEnvironment.liveKitServerToken(for: name, identity: "user", canPublish: true, canPublishData: true)
        let peerToken = try TestEnvironment.liveKitServerToken(for: name, identity: "peer", canPublish: true, canSubscribe: true)
        let source = LatencyTokenSource(response: TokenSourceResponse(serverURL: URL(string: url)!, participantToken: token))
        let ownedTrack = StateSync<LocalAudioTrack?>(nil)
        var dependencies = SessionStartup.Dependencies()
        dependencies.startCapture = { track in
            ownedTrack.mutate { $0 = track }
            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            try await track.start()
        }
        let session = Session(tokenSource: source, options: SessionOptions(room: room, preConnectAudio: buffering))
        session.startupDependencies = dependencies
        do {
            try await peer.connect(url: url, token: peerToken)
            let start = ProcessInfo.processInfo.systemUptime
            if concurrent {
                await session.start()
                if let error = session.error { throw error }
            } else {
                // Previous Session.start(): buffer/capture before credentials+connect, or
                // credentials+connect before capture when preConnectAudio is disabled.
                if buffering { try await startBaselineCapture(room: room, dependencies: dependencies, buffering: true) }
                let response = try await source.fetch()
                try await room.connect(url: response.serverURL.absoluteString, token: response.participantToken)
                if !buffering { try await startBaselineCapture(room: room, dependencies: dependencies, buffering: false) }
            }
            let published = ProcessInfo.processInfo.systemUptime
            let firstAudio = try await observer.audio.wait()
            let connected = try await observer.connected.wait()
            let sample = Sample(concurrent: concurrent, preConnectAudio: buffering, captureDelayMs: delay,
                                repetition: repetition, connectedMs: (connected - start) * 1000,
                                publishedMs: (published - start) * 1000, firstAudioMs: (firstAudio - start) * 1000)
            await session.end()
            await peer.disconnect()
            try await ownedTrack.copy()?.stop()
            return sample
        } catch {
            await session.end()
            await peer.disconnect()
            try? await ownedTrack.copy()?.stop()
            throw error
        }
    }

    @MainActor private static func startBaselineCapture(room: Room, dependencies: SessionStartup.Dependencies, buffering: Bool) async throws {
        let track = try await dependencies.makeTrack(room)
        try await dependencies.startCapture(track)
        if buffering {
            let recorder = LocalAudioTrackRecorder(track: track, format: .pcmFormatInt16,
                                                   sampleRate: PreConnectAudioBuffer.Constants.sampleRate,
                                                   maxSize: PreConnectAudioBuffer.Constants.maxSize)
            try await room.preConnectBuffer.startRecording(timeout: 20, recorder: recorder)
            // Room.connect() publishes the already-recording track on the previous flow.
        } else {
            _ = try await room.localParticipant.publish(audioTrack: track)
        }
    }
}

private struct LatencyTokenSource: TokenSourceFixed {
    let response: TokenSourceResponse
    func fetch() async throws -> TokenSourceResponse {
        try await Task.sleep(nanoseconds: 350_000_000)
        return response
    }
}

private final class StartupLatencyObserver: RoomDelegate, AudioRenderer, @unchecked Sendable {
    let connected = AsyncCompleter<Double>(label: "room connected", defaultTimeout: 10)
    let audio = AsyncCompleter<Double>(label: "first remote decoded audio", defaultTimeout: 10)
    private let rendered = StateSync(false)

    func room(_ room: Room, didUpdateConnectionState state: ConnectionState, from _: ConnectionState) {
        if state == .connected, room.localParticipant.identity?.stringValue == "user" { connected.resume(returning: ProcessInfo.processInfo.systemUptime) }
    }

    func room(_: Room, participant _: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        (publication.track as? RemoteAudioTrack)?.add(audioRenderer: self)
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard pcmBuffer.frameLength > 0 else { return }
        let first = rendered.mutate {
            let first = !$0
            $0 = true
            return first
        }
        if first { audio.resume(returning: ProcessInfo.processInfo.systemUptime) }
    }
}
