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

#if canImport(AVFAudio) && !os(macOS)
import AVFAudio
#endif
import CoreVideo
import Foundation
@testable import LiveKit
import LiveKitUniFFI
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Holds the first task that reaches `step` until resumed: a race made deterministic.
final class Pause: Sendable {
    private let step: Telemetry.GatedStep
    private let armed = StateSync(true)
    private let arrival = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()

    init(at step: Telemetry.GatedStep) {
        self.step = step
    }

    var hook: @Sendable (Telemetry.GatedStep) async -> Void {
        { [self] reached in
            guard reached == step, armed.mutate({ let first = $0; $0 = false; return first }) else { return }
            arrival.continuation.yield()
            for await _ in release.stream {
                return
            }
        }
    }

    func reached() async {
        for await _ in arrival.stream {
            return
        }
    }

    func resume() {
        release.continuation.yield()
    }
}

/// This suite's own stand-in collector: no state shared with other suites' URL protocol mocks.
final class CollectorStub: URLProtocol, @unchecked Sendable {
    struct Answer {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    static let answer = StateSync<Result<Answer, URLError>>(.failure(URLError(.badServerResponse)))

    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "collector.test" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        switch Self.answer.copy() {
        case let .success(answer):
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

/// A microphone the user never allowed: capture fails the way a denied one does.
final class DeniedMicrophone: LocalAudioTrack, @unchecked Sendable {
    convenience init() {
        let track = RTC.createAudioTrack(source: RTC.createAudioSource(nil))
        self.init(name: Track.microphoneName, source: .microphone, track: RTCMediaTrack(track), reportStatistics: false, captureOptions: AudioCaptureOptions())
    }

    override func startCapture() async throws {
        throw LiveKitError(.deviceAccessDenied)
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

/// What the collector wrote: OTLP/JSON, one export request per line.
struct OTLPFile {
    struct Log {
        let eventName: String
        let body: String?
        let traceId: String
        let spanId: String
        let severity: Int
        let attributes: [String: String]
    }

    struct Span {
        let name: String
        let traceId: String
        let start: UInt64
        let end: UInt64
        var seconds: Double { Double(end - start) / 1e9 }
        let attributes: [String: String]
        /// Span event names: the checkpoints (`ws_open`, `first_media`, `attempt 1 quick`, …).
        let events: [String]
        /// When each checkpoint was stamped.
        let eventTimes: [String: UInt64]
    }

    private(set) var logs: [Log] = []
    private(set) var spans: [Span] = []

    init(url: URL, since: UInt64) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n") {
            guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            for scope in Self.children(request, "resourceLogs", "scopeLogs") {
                for record in scope["logRecords"] as? [[String: Any]] ?? [] where Self.nanos(record["timeUnixNano"]) >= since {
                    logs.append(Log(eventName: record["eventName"] as? String ?? "",
                                    body: (record["body"] as? [String: Any])?["stringValue"] as? String,
                                    traceId: record["traceId"] as? String ?? "",
                                    spanId: record["spanId"] as? String ?? "",
                                    severity: record["severityNumber"] as? Int ?? 0,
                                    attributes: Self.attributes(record["attributes"])))
                }
            }
            for scope in Self.children(request, "resourceSpans", "scopeSpans") {
                for span in scope["spans"] as? [[String: Any]] ?? [] where Self.nanos(span["startTimeUnixNano"]) >= since {
                    spans.append(Span(name: span["name"] as? String ?? "",
                                      traceId: span["traceId"] as? String ?? "",
                                      start: Self.nanos(span["startTimeUnixNano"]),
                                      end: Self.nanos(span["endTimeUnixNano"]),
                                      attributes: Self.attributes(span["attributes"]),
                                      events: (span["events"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
                                      eventTimes: Dictionary((span["events"] as? [[String: Any]] ?? []).compactMap { event in
                                          (event["name"] as? String).map { ($0, Self.nanos(event["timeUnixNano"])) }
                                      }, uniquingKeysWith: { first, _ in first })))
                }
            }
        }
    }

    private static func children(_ request: [String: Any], _ resources: String, _ scopes: String) -> [[String: Any]] {
        (request[resources] as? [[String: Any]] ?? []).flatMap { $0[scopes] as? [[String: Any]] ?? [] }
    }

    private static func nanos(_ value: Any?) -> UInt64 {
        (value as? String).flatMap(UInt64.init) ?? (value as? UInt64) ?? 0
    }

    /// OTLP/JSON attributes (`[{key, value: {stringValue | intValue | boolValue | doubleValue}}]`) as strings.
    private static func attributes(_ value: Any?) -> [String: String] {
        var result: [String: String] = [:]
        for pair in value as? [[String: Any]] ?? [] {
            guard let key = pair["key"] as? String, let any = pair["value"] as? [String: Any] else { continue }
            result[key] = any["stringValue"] as? String ?? (any["intValue"] ?? any["boolValue"] ?? any["doubleValue"]).map { "\($0)" }
        }
        return result
    }
}
