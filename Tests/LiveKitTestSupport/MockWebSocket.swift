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

/// Mock WebSocket that captures sent data and tracks close state.
/// Used to test SignalClient's send methods without a real network connection.
///
/// Usage:
/// ```swift
/// let mock = MockWebSocket()
/// await signalClient.setWebSocket(mock)
/// await signalClient.setConnectionState(.connected)
/// try await signalClient.sendMuteTrack(trackSid: Track.Sid(from: "TR_1"), muted: true)
/// XCTAssertEqual(mock.sentRequests.count, 1)
/// XCTAssertTrue(mock.sentRequests[0].hasMute)
/// ```
public final class MockWebSocket: WebSocketType, @unchecked Sendable {
    private let _state = StateSync(State())

    private struct State {
        var sentData: [Data] = []
        var isClosed: Bool = false
        var sendError: LiveKitError?
    }

    public init() {}

    // MARK: - WebSocketType

    public func send(data: Data) async throws {
        let error = _state.read { $0.sendError }
        if let error { throw error }
        _state.mutate { $0.sentData.append(data) }
    }

    public func close() {
        _state.mutate { $0.isClosed = true }
    }

    // MARK: - Test Inspection

    /// All raw Data payloads sent through this socket.
    public var sentData: [Data] {
        _state.read { $0.sentData }
    }

    /// All sent payloads decoded as Livekit_SignalRequest.
    public var sentRequests: [Livekit_SignalRequest] {
        sentData.compactMap { try? Livekit_SignalRequest(serializedBytes: $0) }
    }

    /// Whether `close()` has been called.
    public var isClosed: Bool {
        _state.read { $0.isClosed }
    }

    /// The most recently sent request (convenience).
    public var lastRequest: Livekit_SignalRequest? {
        sentRequests.last
    }

    // MARK: - Test Configuration

    /// Set an error to throw on the next `send` call.
    public func setSendError(_ error: LiveKitError?) {
        _state.mutate { $0.sendError = error }
    }

    /// Clear all recorded sent data.
    public func reset() {
        _state.mutate {
            $0.sentData.removeAll()
            $0.isClosed = false
            $0.sendError = nil
        }
    }
}
