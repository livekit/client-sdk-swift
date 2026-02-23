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

class WebSocketTests: LKTestCase, @unchecked Sendable {
    // MARK: - Cancellation

    func testCancellationDuringConnect() async throws {
        let url = liveKitServerUrl()
        let roomName = "cancel-\(UUID().uuidString.prefix(8))"
        let token = try liveKitServerToken(for: roomName,
                                           identity: "cancel-test",
                                           canPublish: false,
                                           canPublishData: false,
                                           canPublishSources: [],
                                           canSubscribe: false)

        let room = Room()
        let task = Task {
            try await room.connect(url: url, token: token)
        }

        // Cancel after brief delay — timing-dependent, either outcome is valid
        try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            // Connected before cancel fired — clean up
            await room.disconnect()
        case .failure:
            // Cancelled as expected
            break
        }
    }

    func testRapidFireConnectCancel() async throws {
        let url = liveKitServerUrl()
        var cancelled = 0
        var connected = 0

        for i in 1 ... 10 {
            let roomName = "fire-\(UUID().uuidString.prefix(8))"
            let token = try liveKitServerToken(for: roomName,
                                               identity: "fire-\(i)",
                                               canPublish: false,
                                               canPublishData: false,
                                               canPublishSources: [],
                                               canSubscribe: false)
            let room = Room()
            let task = Task {
                try await room.connect(url: url, token: token)
            }

            let delay = UInt64.random(in: 0 ... 5_000_000)
            try? await Task.sleep(nanoseconds: delay)
            task.cancel()

            let result = await task.result
            switch result {
            case .success:
                connected += 1
                await room.disconnect()
            case .failure:
                cancelled += 1
            }
        }

        // At least some should have been cancelled or connected — no crashes
        XCTAssert(connected + cancelled == 10, "Expected 10 total, got \(connected + cancelled)")
    }
}
