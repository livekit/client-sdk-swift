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

/// End to end through the Rust core: needs `livekit-server --dev` and an OTLP collector writing
/// JSON lines to disk — `otelcol-contrib --config Tests/LiveKitCoreTests/Telemetry/otelcol.yaml`
/// (CI starts one; see ci.yaml).
@Suite(.serialized, .tags(.e2e))
struct TelemetryTests {
    static let collectorOutput = URL(fileURLWithPath: "/tmp/livekit-telemetry-otlp.jsonl")

    @Test func statsErrorsAndSpansReachTheCollector() async throws {
        let start = UInt64(Date().timeIntervalSince1970 * 1e9)
        let marker = "telemetry e2e \(UUID().uuidString)"
        let options = try TelemetryOptions(endpoint: #require(URL(string: "http://127.0.0.1:4319/v1/logs")),
                                           storageDirectory: nil,
                                           flushInterval: 1,
                                           statsWindow: 2)
        // Process-wide, configured before the Rooms exist — like an app would at launch
        // (`LiveKitSDK.setTelemetry` is the fire-and-forget form of the same call).
        await Telemetry.shared.configure(options)
        await Telemetry.shared.setAttribute("acme.tenant", .string(marker))

        var traceIds: Set<String> = []
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublish: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            var ids: [String] = []
            for room in rooms {
                if let id = await room.telemetryTraceId { ids.append(id) }
            }
            #expect(ids.count == 2 && ids.allSatisfy { $0.count == 32 }, "each Room has a printable session trace id")
            #expect(ids[0] != ids[1])
            traceIds = Set(ids)

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
            rooms[0].emitTelemetryEvent("e2e.checkpoint", attributes: ["e2e.marker": .string(marker)])
            // Two stats windows plus a flush.
            try await Task.sleep(nanoseconds: 6_000_000_000)
            frames.cancel()
        }
        try await Task.sleep(nanoseconds: 3_000_000_000) // the disconnect flush, and the collector's write

        let otlp = try OTLPFile(url: Self.collectorOutput, since: start)
        let logs = otlp.logs
        #expect(logs.contains { $0.attributes["lk.track.kind"] == "video" && $0.attributes["lk.track.direction"] == "outbound" },
                "outbound video stats window")
        #expect(logs.contains { $0.attributes["lk.room.name"] != nil && $0.attributes["lk.participant.identity"] != nil },
                "session attributes attached")
        #expect(logs.contains { $0.body == marker }, "error record reached the collector")
        #expect(logs.contains { $0.eventName == "custom.e2e.checkpoint" && $0.attributes["e2e.marker"] == marker },
                "custom event reached the collector")
        for event in ["lk.device.thermal.changed", "lk.device.memory.changed", "lk.device.network.changed"] {
            #expect(logs.contains { $0.eventName == event }, "\(event) initial value reached the collector")
        }
        let tenant = Set(logs.filter { $0.attributes["acme.tenant"] == marker }.map(\.traceId))
        #expect(tenant.isSuperset(of: traceIds), "the pipeline-wide attribute reaches every session: \(tenant)")

        // Spans: connect (both rooms), the publisher's publish, the subscriber's subscribe
        // (intent → first media) — under the Rooms' own trace ids.
        let spanNames = Set(otlp.spans.filter { traceIds.contains($0.traceId) }.map(\.name))
        #expect(spanNames.isSuperset(of: ["lk.connect", "lk.publish", "lk.subscribe"]), "spans: \(spanNames)")
    }
}

/// What the collector wrote: OTLP/JSON, one export request per line.
struct OTLPFile {
    struct Log {
        let eventName: String
        let body: String?
        let traceId: String
        let attributes: [String: String]
    }

    struct Span {
        let name: String
        let traceId: String
    }

    private(set) var logs: [Log] = []
    private(set) var spans: [Span] = []

    init(url: URL, since: UInt64) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for resource in request["resourceLogs"] as? [[String: Any]] ?? [] {
                for scope in resource["scopeLogs"] as? [[String: Any]] ?? [] {
                    for record in scope["logRecords"] as? [[String: Any]] ?? [] {
                        guard Self.nanos(record["timeUnixNano"]) >= since else { continue }
                        logs.append(Log(eventName: record["eventName"] as? String ?? "",
                                        body: (record["body"] as? [String: Any])?["stringValue"] as? String,
                                        traceId: record["traceId"] as? String ?? "",
                                        attributes: Self.attributes(record["attributes"])))
                    }
                }
            }
            for resource in request["resourceSpans"] as? [[String: Any]] ?? [] {
                for scope in resource["scopeSpans"] as? [[String: Any]] ?? [] {
                    for span in scope["spans"] as? [[String: Any]] ?? [] {
                        guard Self.nanos(span["startTimeUnixNano"]) >= since else { continue }
                        spans.append(Span(name: span["name"] as? String ?? "", traceId: span["traceId"] as? String ?? ""))
                    }
                }
            }
        }
    }

    private static func nanos(_ value: Any?) -> UInt64 {
        (value as? String).flatMap(UInt64.init) ?? (value as? UInt64) ?? 0
    }

    /// OTLP/JSON attributes (`[{key, value: {stringValue | intValue | boolValue | doubleValue}}]`) as strings.
    private static func attributes(_ value: Any?) -> [String: String] {
        var result: [String: String] = [:]
        for pair in value as? [[String: Any]] ?? [] {
            guard let key = pair["key"] as? String, let any = pair["value"] as? [String: Any] else { continue }
            if let s = any["stringValue"] as? String { result[key] = s }
            else if let i = any["intValue"] { result[key] = "\(i)" }
            else if let b = any["boolValue"] as? Bool { result[key] = String(b) }
            else if let d = any["doubleValue"] as? Double { result[key] = String(d) }
        }
        return result
    }
}
