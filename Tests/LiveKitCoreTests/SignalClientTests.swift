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

struct SignalClientTests {
    /// Matches rust-sdks `get_join_response`/`get_reconnect_response`: from `cleanUp()` until the
    /// next Join/ReconnectResponse, only `join`, `reconnect` and `leave` get through.
    @Test func connectResponseGate() async {
        let client = SignalClient()
        let update = Livekit_SignalResponse.with { $0.update = .with { _ in } }

        await client.cleanUp()
        #expect(await client.passesConnectResponseGate(update) == false)
        #expect(await client.passesConnectResponseGate(.with { $0.leave = .with { _ in } }))
        #expect(await client.passesConnectResponseGate(update) == false, "leave must not open the gate")

        #expect(await client.passesConnectResponseGate(.with { $0.join = .with { _ in } }))
        #expect(await client.passesConnectResponseGate(update))

        await client.cleanUp()
        #expect(await client.passesConnectResponseGate(update) == false, "cleanUp must re-arm the gate")

        #expect(await client.passesConnectResponseGate(.with { $0.reconnect = .with { _ in } }))
        #expect(await client.passesConnectResponseGate(update))
    }

    @Test func messageNameOmitsPayload() {
        let response = Livekit_SignalResponse.with { $0.refreshToken = "secret.jwt" }
        #expect(response.messageName == "refreshToken")
    }
}
