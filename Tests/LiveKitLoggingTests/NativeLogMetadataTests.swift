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
import Testing

struct NativeLogMetadataTests {
    // Captured with LKRTCLogEx from shipped WebRTC 150.7871.08 on macOS and iOS Simulator.
    @Test func shippedApplePrefix() {
        let raw = "(RTCLogging.mm:33): swift_logging_fixture_error\n"
        let record = WebRTCLogCapture.record(raw)
        #expect(record.file == "RTCLogging.mm")
        #expect(record.line == 33)
        #expect(record.body == "(RTCLogging.mm:33): swift_logging_fixture_error")
        #expect(record.logger == "WebRTC")
        #expect(record.function == nil)
        #expect(record.severity == .error)
    }

    @Test(arguments: ["plain error", "prefix (RTCLogging.mm:33): error", "[12:34] (RTCLogging.mm:33): error",
                      "(/private/source.mm:33): error", "(file.mm:0): error", "(file.mm:4294967296): error",
                      "(file.mm:-1): error", "(file.mm:+1): error", "(file.mm:): error", "(file.mm:33) error",
                      "(" + String(repeating: "x", count: 256) + ":33): error"])
    func unverifiedPrefixStaysRaw(_ raw: String) {
        let record = WebRTCLogCapture.record(raw)
        #expect(record.file == nil)
        #expect(record.line == nil)
        #expect(record.body == raw)
    }
}
