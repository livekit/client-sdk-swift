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

extension WebSocketLifecycleTests {
    /// A caller offer with parameters, or among other extensions, still offers permessage-deflate: the server's
    /// acceptance opens the socket, and its compressed messages inflate.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"),
          arguments: ["permessage-deflate; client_max_window_bits", "x-webkit-deflate-frame, PerMessage-Deflate ;server_no_context_takeover"])
    func callerCompressionOfferAcceptsTheNegotiation(offer: String) async throws {
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
        let hello = FakeWebSocketServer.frame(0x42, Data([0xF2, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0]))
        let server = try FakeWebSocketServer(.upgradeResponse(head: head, then: hello + FakeWebSocketServer.close(1000)))
        defer { server.cancel() }

        let socket = try await LiveKit.WebSocket(url: server.url(), headers: [("Sec-WebSocket-Extensions", offer)], timeoutInterval: 10)
        let (received, error) = await Self.messages(of: socket)
        #expect(received == [Data("Hello".utf8)])
        #expect(Self.closeCode(of: error) == 1000)
        #expect(server.requestHeaders.copy().filter { $0.lowercased().hasPrefix("sec-websocket-extensions:") } == ["Sec-WebSocket-Extensions: \(offer)"])
    }

    /// An offer without permessage-deflate still rejects a server that turns it on.
    @Test func compressionNotOfferedIsRejected() async throws {
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
        let server = try FakeWebSocketServer(.upgradeResponse(head: head))
        defer { server.cancel() }
        let error = await #expect(throws: LiveKitError.self) {
            try await LiveKit.WebSocket(url: server.url(), headers: [("Sec-WebSocket-Extensions", "permessage-deflate-x")], timeoutInterval: 10)
        }
        #expect((error?.internalError as? URLError)?.code == .badServerResponse)
    }
}
