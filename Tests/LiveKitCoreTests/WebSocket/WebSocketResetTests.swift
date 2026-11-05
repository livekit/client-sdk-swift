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

import Foundation
@testable import LiveKit
import Network
import Testing

@Suite(.tags(.networking), TestLimits.unit)
struct WebSocketResetTests {
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func listenerPortCollisionFailsWithAddressInUse() async throws {
        let (server, url) = try await FakeWebSocketServer.started(.idle)
        defer { server.cancel() }
        let portNumber = try #require(url.port)
        let port = try #require(NWEndpoint.Port(String(portNumber)))
        let listener = try NWListener(using: .tcp, on: port)
        defer {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        let failed = AsyncCompleter<Void>(label: "WebSocketResetTests.listenerFailed", defaultTimeout: 5)
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state { failed.resume(throwing: error) }
        }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global(qos: .default))
        await #expect(throws: NWError.posix(.EADDRINUSE)) { try await failed.wait() }
    }

    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func peerResetTearsDownBeforeTheReadFailsUnderLoad() async throws {
        let completed = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 4 {
                group.addTask {
                    for _ in 0 ..< 50 {
                        try await WebSocketTestSupport.peerClosure(behavior: .reset, ending: .networkError(posix: ECONNRESET))
                    }
                    return 50
                }
            }
            var rounds = 0
            for try await count in group {
                rounds += count
            }
            return rounds
        }
        #expect(completed == 200)
    }
}
