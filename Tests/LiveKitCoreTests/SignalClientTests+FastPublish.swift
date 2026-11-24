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
import LiveKitWebRTC
import Testing

extension SignalClientTests {
    @Test(arguments: [false, true])
    func addTrackIsSentBeforeNegotiationAndStillWaitsForAcceptance(fast: Bool) async throws {
        let (server, url) = try await FakeWebSocketServer.started(.idle)
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10)
        defer { socket.close() }
        let trace = StateSync<[String]>([])
        let requested = AsyncCompleter<Void>(label: "AddTrack sent", defaultTimeout: 5)
        let negotiated = AsyncCompleter<Void>(label: "negotiation started", defaultTimeout: 5)
        let client = try await SignalClient(testingResponse: .with { $0.refreshToken = "token" }, requestProcessor: { request in
            if case .addTrack = request.message {
                trace.mutate { $0.append("add") }
                requested.resume(returning: ())
            }
        }, responseProcessed: {})
        await client._state.mutate {
            $0.socket = socket
            $0.connectionState = .connected
        }
        await client.resumeQueues()
        let negotiate: @Sendable () async throws -> Void = {
            #expect(trace.copy() == ["add"])
            trace.mutate { $0.append("negotiate") }
            negotiated.resume(returning: ())
        }
        async let published: Livekit_TrackInfo = {
            let info = try await LocalParticipant.publishTrackInfo(.with {
                $0.cid = "pending"
                $0.name = "camera"
                $0.type = .video
            }, client: client, fast: fast, negotiate: negotiate)
            trace.mutate { $0.append("complete") }
            return info
        }()
        try await requested.wait()
        if fast { try await negotiated.wait() }
        #expect(trace.copy() == (fast ? ["add", "negotiate"] : ["add"]))
        let response = Livekit_SignalResponse.with {
            $0.trackPublished = .with {
                $0.cid = "pending"
                $0.track = .with { $0.sid = "TR_accepted" }
            }
        }
        try await client.onWebSocketMessage(.data(response.serializedData()), from: socket)
        #expect(try await published.sid == "TR_accepted")
        #expect(trace.copy() == ["add", "negotiate", "complete"])
        await client.cleanUp()
    }

    @Test func immediateAcceptanceWhileConfiguringSenderIsNotLost() async throws {
        let (server, url) = try await FakeWebSocketServer.started(.idle)
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10)
        defer { socket.close() }
        let client = try await SignalClient(testingResponse: .with { $0.refreshToken = "token" },
                                            requestProcessor: { _ in }, responseProcessed: {})
        await client._state.mutate {
            $0.socket = socket
            $0.connectionState = .connected
        }
        await client.resumeQueues()
        let info = try await LocalParticipant.publishTrackInfo(.with {
            $0.cid = "immediate"
            $0.name = "camera"
            $0.type = .video
        }, client: client, fast: true, negotiate: {
            let response = Livekit_SignalResponse.with {
                $0.trackPublished = .with {
                    $0.cid = "immediate"
                    $0.track = .with { $0.sid = "TR_immediate" }
                }
            }
            try await client.onWebSocketMessage(.data(response.serializedData()), from: socket)
        })
        #expect(info.sid == "TR_immediate")
        await client.cleanUp()
    }

    @Test func republishingSameCIDWaitsForFreshResponse() async throws {
        let (server, url) = try await FakeWebSocketServer.started(.idle)
        defer { server.cancel() }
        let socket = try await LiveKit.WebSocket(url: url, headers: [], timeoutInterval: 10)
        defer { socket.close() }
        let client = try await SignalClient(testingResponse: .with { $0.refreshToken = "token" },
                                            requestProcessor: { _ in }, responseProcessed: {})
        await client._state.mutate {
            $0.socket = socket
            $0.connectionState = .connected
        }
        await client.resumeQueues()
        let request = Livekit_AddTrackRequest.with { $0.cid = "same"; $0.type = .audio }
        for sid in ["TR_first", "TR_second"] {
            try await client.sendAddTrack(request)
            async let info = client.waitForTrack(cid: "same")
            let response = Livekit_SignalResponse.with {
                $0.trackPublished = .with { $0.cid = "same"; $0.track = .with { $0.sid = sid } }
            }
            try await client.onWebSocketMessage(.data(response.serializedData()), from: socket)
            #expect(try await info.sid == sid)
        }
        await client.cleanUp()
    }

    @Test func duplicateRegistrationDoesNotReplaceOriginalWaiter() async throws {
        let map = CompleterMapActor<String>(label: "publication attempts", defaultTimeout: 5)
        try await map.register(for: "same")
        await #expect(throws: LiveKitError.self) { try await map.register(for: "same") }
        await map.resumeIfPresent(returning: "original", for: "same")
        #expect(try await map.wait(for: "same") == "original")
        // A late response cannot prime a future operation.
        await map.resumeIfPresent(returning: "stale", for: "same")
        try await map.register(for: "same")
        await map.resumeIfPresent(returning: "fresh", for: "same")
        #expect(try await map.wait(for: "same") == "fresh")
    }
}
