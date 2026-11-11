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
import Testing

/// A URL without a port, as every LiveKit Cloud URL is, reaches the scheme's default port. These bind 80 and 443 on
/// this machine, which macOS allows without root. Another process on those ports makes them fail, not skip.
@Suite(.serialized, .tags(.networking), TestLimits.unit,
       .bug("https://github.com/livekit/client-sdk-swift/pull/1191#pullrequestreview-5779686770"))
struct WebSocketDefaultPortTests {
    @Test func portlessWSReachesPort80() async throws {
        let server = try FakeWebSocketServer(.idle, port: 80)
        defer { server.cancel() }
        _ = try await server.url()
        let socket = try await LiveKit.WebSocket(url: #require(URL(string: "ws://127.0.0.1/rtc")), headers: [], timeoutInterval: 10)
        socket.close()
        _ = try await server.clientGone.wait()
        #expect(server.acceptCount.copy() == 1)
        #expect(server.requestHeaders.copy().contains("Host: 127.0.0.1"))
    }

    @Test func portlessWSSReachesPort443() async throws {
        let server = try FakeWebSocketServer(.tlsClientHello, port: 443)
        defer { server.cancel() }
        _ = try await server.url()
        let url = try #require(URL(string: "wss://127.0.0.1/rtc"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let socket = try? await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 5)
                socket?.close()
            }
            let hello = try await server.clientHello.wait()
            #expect(hello.first == 0x16) // A TLS handshake record.
            group.cancelAll()
        }
        #expect(server.acceptCount.copy() == 1)
    }
}
