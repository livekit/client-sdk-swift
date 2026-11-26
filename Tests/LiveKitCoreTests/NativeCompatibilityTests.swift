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
    func publishingOptionsUseCoreValues() throws {
        let audio = try AudioPublishOptions(encoding: .init(maxBitrate: 32000), dtx: false,
                                            streamName: "voice", preConnect: true).coreOptions()
        #expect(audio.audioEncoding?.maxBitrate == 32000)
        #expect(!audio.dtx && audio.red && audio.preconnectBuffer)
        #expect(audio.source == .microphone && audio.stream == "voice")
        let video = VideoPublishOptions(encoding: .init(maxBitrate: 800_000, maxFps: 30),
                                        screenShareEncoding: .init(maxBitrate: 400_000, maxFps: 10),
                                        simulcastLayers: [.init(dimensions: .init(width: 320, height: 180),
                                                                encoding: .init(maxBitrate: 100_000, maxFps: 15))],
                                        preferredCodec: .vp9, degradationPreference: .maintainResolution)
        let camera = try video.coreOptions(screenShare: false)
        let screen = try video.coreOptions(screenShare: true)
        #expect(camera.videoEncoding?.maxBitrate == 800_000)
        #expect(camera.simulcastLayers?.first?.width == 320)
        #expect(camera.videoCodec == .vp9 && camera.degradationPreference == .maintainResolution)
        #expect(screen.source == .screenshare && screen.videoEncoding?.maxFramerate == 10)
        #expect(screen.simulcastLayers == nil)
        #expect(throws: LiveKitError.self) { try AudioPublishOptions(encoding: .init(maxBitrate: -1)).coreOptions() }
        #expect(throws: LiveKitError.self) { try VideoPublishOptions(encoding: .init(maxBitrate: 1, maxFps: 0)).coreOptions(screenShare: false) }
        #expect(throws: LiveKitError.self) { try VideoPublishOptions(preferredBackupCodec: .vp8).coreOptions(screenShare: false) }
    }

    @Test
    func iceConfigurationUsesNativeFields() throws {
        let server = IceServer(urls: ["turn:127.0.0.1:3478"], username: "test-user", credential: "test-password")
        let options = try NativeRoomDriver.options(.init(iceServers: [server], iceTransportPolicy: .relay), RoomOptions())
        #expect(options.iceServers() == [.init(urls: server.urls, username: "test-user", password: "test-password")])
        #expect(options.iceTransportPolicy() == .relay)
        #expect(options.sdk() == "swift")
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
