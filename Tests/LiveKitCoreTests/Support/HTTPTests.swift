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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Tests for the HTTP utility class.
/// Uses fast-failing connections (unreachable localhost ports) to test error paths
/// without requiring a real server.
class HTTPTests: LKTestCase {
    // MARK: - requestValidation error paths

    func testRequestValidationConnectionRefused() async {
        // Port 1 is almost certainly not listening — connection will be refused quickly
        let url = URL(string: "http://127.0.0.1:1/rtc/validate")!
        do {
            try await HTTP.requestValidation(from: url, token: "test-token")
            XCTFail("Should have thrown for unreachable server")
        } catch {
            // Should throw a URLError or similar network error
            XCTAssertFalse(error is LiveKitError, "Connection failure should throw URLError, not LiveKitError")
        }
    }

    // MARK: - prewarmConnection

    func testPrewarmConnectionDoesNotThrow() async {
        // prewarmConnection silently fails — verify it doesn't crash
        let url = URL(string: "wss://127.0.0.1:1")!
        await HTTP.prewarmConnection(url: url)
        // If we get here, it didn't crash (best-effort connection warming)
    }
}
