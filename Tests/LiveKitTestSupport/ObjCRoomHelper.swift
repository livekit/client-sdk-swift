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
import LiveKitUniFFI

/// ObjC-compatible helper for generating tokens and reading server configuration.
@objcMembers
public class LKObjCRoomHelper: NSObject {
    private static let connectAttempts = 3
    private static let connectRetryDelay: TimeInterval = 2

    /// How long a caller must allow for ``connect(room:url:token:completionHandler:)`` to report.
    ///
    /// The retry loop can legitimately run for `attempts × (connect timeout + delay)`, which
    /// already exceeds the 30 s the ObjC tests used to allow — so one slow cold connect, the very
    /// case the retry exists for, blew the XCTest expectation before the retry could save it.
    /// Derived rather than written down twice: changing the attempt count or the connect timeout
    /// must move this with it.
    public static var connectTimeout: TimeInterval {
        let perAttempt = ConnectOptions().primaryTransportConnectTimeout + connectRetryDelay
        // The readiness wait comes first and is bounded on its own; a server that never answers
        // must still report through the completion handler before the caller's expectation expires.
        return TestEnvironment.serverReadyTimeout + TimeInterval(connectAttempts) * perAttempt + 10 // slack for the one-time WebRTC init
    }

    /// Connects with retries, matching `TestEnvironment.withRooms`. The first `Room`
    /// in a process pays one-time WebRTC and audio-stack initialization that can
    /// exceed the connect timeout on a simulator.
    @objc(connectWithRoom:url:token:completionHandler:)
    public static func connect(room: Room,
                               url: String,
                               token: String,
                               completionHandler: @escaping @Sendable (Error?) -> Void)
    {
        Task {
            do {
                try await TestEnvironment.waitForServer(url)
            } catch {
                completionHandler(error)
                return
            }
            var lastError: Error?
            for attempt in 1 ... connectAttempts {
                do {
                    try await room.connect(url: url, token: token)
                    completionHandler(nil)
                    return
                } catch {
                    lastError = error
                    // Reset so a half-established connect doesn't leak a participant.
                    await room.disconnect()
                    if attempt < connectAttempts {
                        try? await Task.sleep(nanoseconds: UInt64(connectRetryDelay * 1_000_000_000))
                    }
                }
            }
            completionHandler(lastError)
        }
    }

    public static func serverURL() -> String {
        if let string = ProcessInfo.processInfo.environment["LIVEKIT_TESTING_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !string.isEmpty
        {
            return string
        }
        return "ws://localhost:7880"
    }

    public static func generateToken(
        roomName: String,
        identity: String,
        canPublish: Bool,
        canPublishData: Bool,
        canSubscribe: Bool,
    ) throws -> String {
        let apiKey = readEnv("LIVEKIT_TESTING_API_KEY", defaultValue: "devkey")
        let apiSecret = readEnv("LIVEKIT_TESTING_API_SECRET", defaultValue: "secret")

        let tokenGenerator = TokenGenerator(apiKey: apiKey,
                                            apiSecret: apiSecret,
                                            identity: identity)

        tokenGenerator.videoGrants = VideoGrants(
            roomCreate: false,
            roomList: false,
            roomRecord: false,
            roomAdmin: false,
            roomJoin: true,
            room: roomName,
            destinationRoom: "",
            canPublish: canPublish,
            canSubscribe: canSubscribe,
            canPublishData: canPublishData,
            canPublishSources: [],
            canUpdateOwnMetadata: false,
            ingressAdmin: false,
            hidden: false,
            recorder: false,
        )

        return try tokenGenerator.sign()
    }

    private static func readEnv(_ key: String, defaultValue: String) -> String {
        if let string = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !string.isEmpty
        {
            return string
        }
        return defaultValue
    }
}
