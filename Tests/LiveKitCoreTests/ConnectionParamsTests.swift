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

/// Client capabilities must be advertised on *both* connection paths (query-param and
/// join-request); otherwise peers connected via the path that omits them never enable the
/// corresponding feature (e.g. deflate compression).
struct ConnectionParamsTests {
    private let url = URL(string: "wss://example.livekit.cloud")!

    @Test func queryParamPathAdvertisesCapabilities() throws {
        let built = try Utils.buildUrl(url, adaptiveStream: false)
        let queryItems = URLComponents(url: built, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let capabilities = queryItems.first { $0.name == "capabilities" }?.value
        #expect(capabilities?.contains("CAP_COMPRESSION_DEFLATE_RAW") == true)
    }

    @Test func joinRequestPathAdvertisesCapabilities() throws {
        let built = try Utils.buildJoinRequestUrl(url, adaptiveStream: false)
        let queryItems = URLComponents(url: built, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let encoded = try #require(queryItems.first { $0.name == "join_request" }?.value)
        let wrappedData = try #require(Data(base64Encoded: encoded))

        let wrapped = try Livekit_WrappedJoinRequest(serializedBytes: wrappedData)
        let joinRequest = try Livekit_JoinRequest(serializedBytes: wrapped.joinRequest)
        #expect(joinRequest.clientInfo.capabilities.contains(.capCompressionDeflateRaw))
    }
}
