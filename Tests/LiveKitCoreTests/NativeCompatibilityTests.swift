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
import LiveKitFFI
import Testing

struct NativeCompatibilityTests {
    @Test
    func typedCausesIgnoreMisleadingReasons() {
        let validation = LiveKitError.from(native: .Signal(failure: .http(source: .serverValidation, status: 401, reason: "timeout")))
        #expect(validation.type == .validation)
        #expect(validation.statusCode == 401)
        let handshake = LiveKitError.from(native: .Signal(failure: .http(source: .webSocketHandshake, status: 401, reason: "invalid token")))
        #expect(handshake.type == .network)
        #expect(handshake.statusCode == 401)
        #expect(LiveKitError.from(native: .Signal(failure: .http(source: .clientValidation, status: 404, reason: nil))).type == .serviceNotFound)
        #expect(LiveKitError.from(native: .Signal(failure: .timeout(reason: "401 forbidden"))).type == .timedOut)
        #expect(LiveKitError.from(native: .RequestFailure(code: .notAllowed, reason: "timeout")).type == .insufficientPermissions)
        #expect(StreamError.fromNative(.Cancelled) is CancellationError)
        #expect(StreamError.fromNative(.IoFailure(kind: .notFound, rawOsError: 2, reason: "file")) as? StreamError == .io(reason: "file"))
    }

    @Test
    func iceConfigurationUsesNativeFields() throws {
        let server = IceServer(urls: ["turn:127.0.0.1:3478"], username: "test-user", credential: "test-password")
        let options = try NativeRoomDriver.options(.init(iceServers: [server], iceTransportPolicy: .relay), RoomOptions())
        #expect(options.iceServers == [.init(urls: server.urls, username: "test-user", password: "test-password")])
        #expect(options.iceTransportPolicy == .relay)
        #expect(options.clientProtocol == 2)
        #expect(throws: LiveKitError.self) { try NativeRoomDriver.options(.init(iceTransportPolicy: .none), RoomOptions()) }
        #expect(throws: LiveKitError.self) { try NativeRoomDriver.options(.init(clientProtocol: .v0), RoomOptions()) }
    }
}

extension NativeRoomTests {
    @Test
    func serverPermissionErrorKeepsTypedCause() async throws {
        let room = Room()
        do {
            try await room.connect(url: url, token: token("denied", room: "swift-permission-\(UUID().uuidString)", canUpdateMetadata: false))
            do {
                try await room.localParticipant.set(metadata: "forbidden")
                Issue.record("Expected server permission rejection")
            } catch let error as LiveKitError {
                #expect(error.type == .insufficientPermissions)
                guard case .RequestFailure(code: .notAllowed, reason: _) = error.internalError as? NativeSessionError else {
                    Issue.record("Original typed request error missing")
                    await room.disconnect()
                    return
                }
            }
            await room.disconnect()
        } catch {
            await room.disconnect()
            throw error
        }
    }
}
