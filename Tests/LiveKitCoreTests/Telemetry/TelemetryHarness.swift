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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Headless macOS harness for the whole telemetry path — Swift instruments → Rust core → HTTP →
/// collector — on synthetic media: no device, no permissions, no phone. Needs `livekit-server --dev`
/// and a collector on :4319 (`otelcol-contrib --config Tests/LiveKitCoreTests/Telemetry/otelcol-lgtm.yaml`
/// also fans the session out to a Grafana LGTM stack for browsing); `make telemetry-harness` runs it.
///
/// `LIVEKIT_TELEMETRY_HOLD=<seconds>` keeps the session alive longer, to watch it live in Grafana.
/// `LIVEKIT_TELEMETRY_ENDPOINT=<url>` and `LIVEKIT_TELEMETRY_TOKEN=<jwt>` point the same session at
/// LiveKit Cloud instead (`https://<project>/observability/client/logs/otlp/v0`, a token with an
/// `observability:write` grant) — how the upload policy gets exercised against the real ingest,
/// rate limits included.
///
/// Part of the `TelemetryTests` suite: the pipeline is process-wide, so its tests must not overlap.
extension TelemetryTests {
    /// One full session: connect → publish audio + video → the subscriber gets media → quick
    /// reconnect → full reconnect → disconnect. Everything the core promises about it must be in
    /// the collector afterwards, the disconnect flush included.
    @Test func sessionWithReconnects() async throws {
        let start = UInt64(Date().timeIntervalSince1970 * 1e9)
        // `LIVEKIT_TELEMETRY_ENDPOINT` (+ `LIVEKIT_TELEMETRY_TOKEN`) sends the session to a real
        // collector — LiveKit Cloud — instead of the local one. The collector's file is then empty,
        // so such a run reports the pipeline's own account of the upload policy rather than asserting.
        let environment = ProcessInfo.processInfo.environment
        let cloud = environment["LIVEKIT_TELEMETRY_ENDPOINT"]
        let options = try TelemetryOptions(endpoint: #require(URL(string: cloud ?? "http://127.0.0.1:4319/v1/logs")),
                                           headers: environment["LIVEKIT_TELEMETRY_TOKEN"].map { ["Authorization": "Bearer \($0)"] } ?? [:],
                                           flushInterval: 1, statsWindow: 2)
        await Telemetry.configure(options)

        var publisherTrace = "", subscriberTrace = ""
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublish: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let publisher = rooms[0], subscriber = rooms[1]
            publisherTrace = try #require(await publisher.telemetryTraceId)
            subscriberTrace = try #require(await subscriber.telemetryTraceId)

            let video = LocalVideoTrack.createBufferTrack(name: "harness")
            let frames = try #require(video.capturer as? BufferCapturer).feedSyntheticFrames()
            defer { frames.cancel() }
            try await publisher.localParticipant.publish(videoTrack: video)
            try await publisher.localParticipant.publish(audioTrack: TestAudioTrack())

            let identity = try #require(publisher.localParticipant.identity)
            let remote = try #require(subscriber.remoteParticipants[identity])
            try await poll(timeout: 15, interval: 0.2, for: "subscriber has audio and video") {
                remote.audioTracks.first?.track != nil && remote.videoTracks.first?.track != nil
            }

            try await publisher.debug_simulate(scenario: .quickReconnect)
            try await poll(timeout: 30, interval: 0.2, for: "quick reconnect settled") { publisher.connectionState == .connected }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await publisher.debug_simulate(scenario: .fullReconnect)
            try await poll(timeout: 30, interval: 0.2, for: "full reconnect settled") { publisher.connectionState == .connected }

            // Two stats windows after the reconnects, plus whatever the operator asked for.
            let hold = ProcessInfo.processInfo.environment["LIVEKIT_TELEMETRY_HOLD"].flatMap(Double.init) ?? 0
            try await Task.sleep(nanoseconds: UInt64((5 + hold) * 1e9))
            print("telemetry harness: trace \(publisherTrace) — \(Telemetry.diagnostics())")
        }
        try await Task.sleep(nanoseconds: 3_000_000_000) // the disconnect flush, and the collector's write

        // A cloud run has no local file to read: watch the pipeline instead, long enough for a
        // throttle hold (60 s) to expire and the backlog to ship.
        if cloud != nil {
            for _ in 0 ..< 8 {
                print("telemetry harness: \(Telemetry.diagnostics())")
                try await Task.sleep(nanoseconds: 15_000_000_000)
            }
            return
        }

        // Only this session's records: other e2e tests share the process pipeline and the collector.
        let mine: Set<String> = [publisherTrace, subscriberTrace]
        let otlp = try OTLPFile(url: Self.collectorOutput, since: start)
        let spans = otlp.spans.filter { $0.traceId == publisherTrace }

        // The user-initiated connect, with its steps; reconnects are their own spans.
        let connects = spans.filter { $0.name == "lk.connect" }
        #expect(connects.count == 1, "one lk.connect per session: \(connects.count)")
        let connect = try #require(connects.first)
        #expect(Set(connect.events).isSuperset(of: ["ws_open", "signal", "join_recv", "pc_connected", "room_connected"]), "\(connect.events)")
        #expect(connect.attributes["lk.outcome"] == "ok")

        let reconnects = spans.filter { $0.name == "lk.reconnect" }
        #expect(reconnects.count == 2, "one quick, one full: \(reconnects.map(\.attributes))")
        #expect(reconnects.allSatisfy { $0.attributes["lk.reconnect.reason"] == "debug" && $0.attributes["lk.outcome"] == "ok" }, "\(reconnects.map(\.attributes))")
        #expect(Set(reconnects.compactMap { $0.attributes["lk.reconnect.mode"] }) == ["quick", "full"])
        #expect(reconnects.allSatisfy { $0.events.contains { $0.hasPrefix("attempt 1 ") } }, "\(reconnects.map(\.events))")

        // Publisher side: a publish span per track; subscriber side: intent → first media.
        #expect(spans.filter { $0.name == "lk.publish" }.count >= 2, "audio + video publish spans")
        let subscribes = otlp.spans.filter { $0.name == "lk.subscribe" && $0.traceId == subscriberTrace && $0.events.contains("first_media") }
        #expect(subscribes.count >= 2, "subscribe spans reaching first media: \(subscribes.count)")

        // One stats window per track and direction.
        let windows = otlp.logs.filter { $0.eventName == "lk.rtc.stats.sample" && mine.contains($0.traceId) }
        for (kind, direction) in [("audio", "outbound"), ("video", "outbound"), ("audio", "inbound"), ("video", "inbound")] {
            #expect(windows.contains { $0.attributes["lk.track.kind"] == kind && $0.attributes["lk.track.direction"] == direction },
                    "\(direction) \(kind) window")
        }
        #expect(windows.allSatisfy { $0.attributes["lk.room.name"] != nil && $0.attributes["lk.participant.identity"] != nil },
                "every window carries the room scope")
        // Both Rooms hung up themselves, and said so before the disconnect flush.
        let ended = otlp.logs.filter { $0.eventName == "lk.room.disconnected" && mine.contains($0.traceId) }
        #expect(ended.count == 2 && ended.allSatisfy { $0.attributes["lk.disconnect.reason"] == "client_initiated" }, "\(ended.map(\.attributes))")
        // The pipeline's own health: the whole session shipped.
        #expect(Telemetry.diagnostics().contains("lost 0"), Comment(rawValue: Telemetry.diagnostics()))
    }

    /// The Swift transport is a bytes mover: status, headers and body reach the core untouched
    /// (the core turns 429 + `RetryInfo` into a hold and "disabled" into silence — its own tests
    /// cover that), and only a missing response is an error.
    @Test func transportPassesTheCollectorAnswerThrough() async throws {
        MockURLProtocol.setAllowedHosts(["collector.test"])
        MockURLProtocol.setAllowedPaths(["/v1/logs"])
        defer { MockURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let transport = URLSessionTelemetryTransport(session: URLSession(configuration: configuration))
        MockURLProtocol.setRequestHandler { _ in
            MockURLProtocol.Response(statusCode: 429, headers: ["Retry-After": "7"], body: Data("quota".utf8))
        }
        // UniFFI types stay internal to LiveKit, so the request is spelled through the parameter type.
        let response = try await transport.send(request: .init(url: "http://collector.test/v1/logs",
                                                               headers: ["Content-Type": "application/x-protobuf"],
                                                               body: Data([1, 2, 3])))

        #expect(response.status == 429)
        #expect(response.headers["Retry-After"] == "7")
        #expect(response.body == Data("quota".utf8))

        MockURLProtocol.setRequestHandler { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: (any Error).self, "no response is the transport's only error") {
            try await transport.send(request: .init(url: "http://collector.test/v1/logs", headers: [:], body: Data()))
        }
    }
}

extension BufferCapturer {
    /// 10 fps of the same 320×240 frame: enough for encoders, stats and simulcast layers to exist.
    func feedSyntheticFrames() -> Task<Void, Never> {
        Task {
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess,
                  let pixelBuffer else { return }
            while !Task.isCancelled {
                capture(pixelBuffer)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}
