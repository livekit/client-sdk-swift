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

/// End to end through the Rust core: needs `livekit-server --dev` and an OTLP collector with a
/// Loki query API on localhost (`docker run -p 4318:4318 -p 3100:3100 grafana/otel-lgtm`).
@Suite(.serialized, .tags(.e2e))
struct TelemetryTests {
    @Test func statsAndErrorsReachTheCollector() async throws {
        let start = UInt64(Date().timeIntervalSince1970 * 1e9) - 5_000_000_000
        let marker = "telemetry e2e \(UUID().uuidString)"
        let options = try TelemetryOptions(endpoint: #require(URL(string: "http://localhost:4318/v1/logs")),
                                           storageDirectory: nil,
                                           flushInterval: 1,
                                           statsWindow: 2)

        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublish: true, telemetry: options),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            // Synthetic frames: no capture device or permission needed in a headless test run.
            let track = LocalVideoTrack.createBufferTrack(name: "telemetry")
            let capturer = try #require(track.capturer as? BufferCapturer)
            let frames = Task {
                var pixelBuffer: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &pixelBuffer) == kCVReturnSuccess,
                      let pixelBuffer else { return }
                while !Task.isCancelled {
                    capturer.capture(pixelBuffer)
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            try await rooms[0].localParticipant.publish(videoTrack: track)
            rooms[0].log(marker, .error)
            // Two stats windows plus a flush.
            try await Task.sleep(nanoseconds: 6_000_000_000)
            frames.cancel()
        }
        try await Task.sleep(nanoseconds: 3_000_000_000) // collector ingestion

        let streams = try await loki(query: "{service_name=\"livekit-client-swift\"}", since: start)
        let labels = streams.map(\.labels)
        #expect(labels.contains { $0["lk_track_kind"] == "video" && $0["lk_track_direction"] == "outbound" },
                "outbound video stats window, got \(labels)")
        #expect(labels.contains { $0["lk_room_name"] != nil && $0["lk_participant_identity"] != nil },
                "session attributes attached")
        #expect(streams.contains { $0.lines.contains { $0.contains(marker) } }, "error record reached the collector")
    }

    struct Stream {
        let labels: [String: String]
        let lines: [String]
    }

    func loki(query: String, since: UInt64) async throws -> [Stream] {
        var components = URLComponents(string: "http://localhost:3100/loki/api/v1/query_range")!
        components.queryItems = [
            .init(name: "query", value: query),
            .init(name: "start", value: String(since)),
            .init(name: "limit", value: "500"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = ((json?["data"] as? [String: Any])?["result"] as? [[String: Any]]) ?? []
        return result.map { entry in
            Stream(labels: (entry["stream"] as? [String: String]) ?? [:],
                   lines: ((entry["values"] as? [[Any]]) ?? []).compactMap { $0.count > 1 ? $0[1] as? String : nil })
        }
    }
}
