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

/// Opt-in real Opus/SFU/decoder benchmark, using generated PCM instead of a physical microphone.
@Suite(.serialized, .tags(.e2e), .enabled(if: ProcessInfo.processInfo.environment["LK_SESSION_BENCHMARK"] == "1"))
struct SessionPublicationBenchmarkTests {
    @Test @MainActor func firstDecodedAudio() async throws {
        try await SessionTestAudioSource.withAudio { try await runSamples() }
    }

    @MainActor private func runSamples() async throws {
        let count = Int(ProcessInfo.processInfo.environment["LK_SESSION_BENCHMARK_SAMPLES"] ?? "3") ?? 3
        for singlePC in [true, false] {
            for delay in [0, 800] {
                for sample in -1 ..< count {
                    for prepared in sample.isMultiple(of: 2) ? [false, true] : [true, false] {
                        try await measure(singlePC: singlePC, captureDelay: delay, prepared: prepared, sample: sample)
                    }
                }
            }
        }
    }

    @MainActor private func measure(singlePC: Bool, captureDelay: Int, prepared: Bool, sample: Int) async throws {
        let name = "session-bench-\(UUID().uuidString)"
        let observer = AudioArrival()
        let receiver = Room(delegate: observer)
        let incoming = AudioArrival()
        let publisher = Room(delegate: incoming, roomOptions: RoomOptions(defaultAudioCaptureOptions: .noProcessing,
                                                                          singlePeerConnection: singlePC))
        let token = try TestEnvironment.liveKitServerToken(for: name, identity: "microphone", canPublish: true, canPublishData: true)
        let source = BenchmarkTokenSource(token: token)
        let session = Session(tokenSource: source, options: SessionOptions(room: publisher, preConnectAudio: true))
        try await receiver.connect(url: TestEnvironment.liveKitServerUrl(),
                                   token: TestEnvironment.liveKitServerToken(for: name, identity: "receiver", canPublish: true))
        // A warm companion already has audio ready, like an agent greeting immediately on JOIN.
        try await receiver.localParticipant.setMicrophone(enabled: true, captureOptions: .noProcessing)
        let captureReady = StateSync<TimeInterval?>(nil)
        session.startupDependencies.startCapture = { track in
            try await Task.sleep(nanoseconds: UInt64(captureDelay) * 1_000_000)
            try await track.start()
            captureReady.mutate { $0 = ProcessInfo.processInfo.systemUptime }
        }
        let began = ProcessInfo.processInfo.systemUptime
        let connectionObserver = ConnectionArrival()
        publisher.add(delegate: connectionObserver)
        do {
            if prepared {
                await session.start()
                if let error = session.error { throw error }
            } else {
                // The previous Session.start sequence: capture -> credentials -> connect,
                // followed by Room.connect's existing pre-connect microphone publication.
                try await Task.sleep(nanoseconds: UInt64(captureDelay) * 1_000_000)
                try await publisher.withPreConnectAudio(timeout: 20) {
                    let response = try await source.fetch()
                    try await publisher.connect(url: response.serverURL.absoluteString, token: response.participantToken)
                }
            }
            try await poll(timeout: 15, for: "non-silent decoded remote PCM") { observer.firstAudio != nil }
            try await poll(timeout: 15, for: "decoded companion audio at Session") { incoming.firstAudio != nil }
            let downlink = try #require(incoming.firstAudio)
            let audio = try #require(observer.firstAudio)
            let connected = try #require(connectionObserver.connected)
            if prepared { #expect(audio >= (captureReady.read { $0 } ?? .infinity), "Reserved sender transmitted before capture was ready") }
            print("SESSION_AUDIO_BENCH \(singlePC ? "spc" : "dual"),\(captureDelay),\(sample),\(prepared ? "prepared" : "baseline"),\((connected - began) * 1000),\((audio - began) * 1000),\((downlink - began) * 1000)")
            try await reportNetwork(room: publisher, singlePC: singlePC, captureDelay: captureDelay, sample: sample, prepared: prepared)
        } catch {
            await session.end()
            await receiver.disconnect()
            throw error
        }
        await session.end()
        await receiver.disconnect()
    }

    @MainActor private func reportNetwork(room: Room, singlePC: Bool, captureDelay: Int, sample: Int, prepared: Bool) async throws {
        let track = try #require(room.localParticipant.localAudioTracks.first?.track)
        await track._onStatsTimer()
        let statistics = track.statistics
        let pairID = statistics?.transportStats?.selectedCandidatePairId
        let pair = statistics?.iceCandidatePair.first { $0.id == pairID }
        let signalRTT = try await room.signalClient.benchmarkRoundTripTime()
        let data: [String: Any] = try [
            "pc": singlePC ? "spc" : "dual", "capture_delay_ms": captureDelay, "sample": sample,
            "mode": prepared ? "prepared" : "baseline",
            "actual_single_pc": room.requirePublisher().singlePCMode,
            "join_track_used": track._state.publicationCid != track.mediaTrack.trackId,
            "ice_rtt_ms": pair?.currentRoundTripTime.map { $0 * 1000 } ?? -1,
            "signal_rtt_ms": signalRTT,
            "media_protocol": statistics?.remoteIceCandidate?.protocol ?? "unknown",
        ]
        let json = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
        try print("SESSION_AUDIO_NETWORK " + #require(String(data: json, encoding: .utf8)))
    }
}

private struct BenchmarkTokenSource: TokenSourceFixed {
    let token: String
    func fetch() async throws -> TokenSourceResponse {
        try await Task.sleep(nanoseconds: 100_000_000)
        return TokenSourceResponse(serverURL: URL(string: TestEnvironment.liveKitServerUrl())!, participantToken: token)
    }
}

private final class ConnectionArrival: RoomDelegate, @unchecked Sendable {
    private let state = StateSync<TimeInterval?>(nil)
    var connected: TimeInterval? { state.read { $0 } }
    func room(_: Room, didUpdateConnectionState connectionState: ConnectionState, from _: ConnectionState) {
        if connectionState == .connected { state.mutate { $0 = $0 ?? ProcessInfo.processInfo.systemUptime } }
    }
}

private final class AudioArrival: RoomDelegate, AudioRenderer, @unchecked Sendable {
    private let state = StateSync<TimeInterval?>(nil)
    var firstAudio: TimeInterval? { state.read { $0 } }
    func room(_: Room, participant _: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        (publication.track as? RemoteAudioTrack)?.add(audioRenderer: self)
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard firstAudio == nil else { return }
        let audible: Bool = if let channel = pcmBuffer.floatChannelData {
            (0 ..< Int(pcmBuffer.frameLength)).contains { abs(channel[0][$0]) > 0.005 }
        } else if let channel = pcmBuffer.int16ChannelData {
            (0 ..< Int(pcmBuffer.frameLength)).contains { abs(Int(channel[0][$0])) > 160 }
        } else {
            false
        }
        if audible { state.mutate { $0 = $0 ?? ProcessInfo.processInfo.systemUptime } }
    }
}

private extension SignalClient {
    func benchmarkRoundTripTime() async throws -> Int64 {
        let state = _state
        state.mutate { $0.rtt = 0 }
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        try await sendRequest(.with { $0.pingReq = .with { $0.timestamp = timestamp } })
        try await poll(timeout: 5, for: "signaling ping response") { state.rtt > 0 }
        return state.rtt
    }
}
