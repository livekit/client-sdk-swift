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
    private static let connectRetryDelay: UInt64 = 2_000_000_000

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
                        try? await Task.sleep(nanoseconds: connectRetryDelay)
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
