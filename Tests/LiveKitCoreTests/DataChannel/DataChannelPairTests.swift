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

/// Unit-level coverage for the parts of `DataChannelPair` that don't need a
/// real `LKRTCDataChannel`: the pre-flight `openCompleter` semantics and the
/// `.drain` path that fails parked sends after `reset(throwing:)`. Anything
/// that needs real `sendData` dispatch or `bufferedAmount` drains is exercised
/// by `RealiableDataChannelTests` / `EncryptedDataChannelTests` end-to-end.
@Suite(.tags(.dataChannel))
struct DataChannelPairTests {
    @Test func openCompleterTimesOutWhenChannelsNeverArrive() async {
        let pair = DataChannelPair()
        await #expect {
            try await pair.openCompleter.wait(timeout: 0.1)
        } throws: { ($0 as? LiveKitError)?.type == .timedOut }
    }

    @Test func resetFailsParkedSendsWithProvidedError() async throws {
        let pair = DataChannelPair()

        // No channels are set, so the send enqueues and parks.
        let sendTask = Task {
            try await pair.send(userPacket: Livekit_UserPacket(), kind: .reliable)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        pair.reset(throwing: LiveKitError(.invalidState, message: "custom"))
        await #expect {
            try await sendTask.value
        } throws: { ($0 as? LiveKitError)?.type == .invalidState }
    }

    @Test func resetWithNilErrorFailsParkedSendsAsCancelled() async throws {
        let pair = DataChannelPair()

        let sendTask = Task {
            try await pair.send(userPacket: Livekit_UserPacket(), kind: .reliable)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        pair.reset(throwing: nil)
        await #expect {
            try await sendTask.value
        } throws: { ($0 as? LiveKitError)?.type == .cancelled }
    }

    @Test func openCompleterWaitHonorsTaskCancellation() async {
        let pair = DataChannelPair()
        let waitTask = Task { try await pair.openCompleter.wait() }
        await pair.openCompleter.waitForRegistration()

        waitTask.cancel()
        await #expect {
            try await waitTask.value
        } throws: { ($0 as? LiveKitError)?.type == .cancelled }
    }

    @Test func oversizedSendRejectedWithInvalidParameter() async throws {
        let pair = DataChannelPair()
        pair.set(maxMessageSize: 1024)

        let oversizedPayload = Data(repeating: 0xAB, count: 4096)
        await #expect {
            try await pair.send(userPacket: .with { $0.payload = oversizedPayload }, kind: .reliable)
        } throws: { ($0 as? LiveKitError)?.type == .invalidParameter }
    }

    @Test func zeroLimitDisablesTheSizeGuard() async throws {
        let pair = DataChannelPair()
        pair.set(maxMessageSize: 0)

        // Without channels, the send parks indefinitely; we only want to verify
        // that the size check does NOT short-circuit the request first.
        let sendTask = Task {
            try await pair.send(userPacket: .with { $0.payload = Data(repeating: 0xCD, count: 200_000) }, kind: .reliable)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        pair.reset(throwing: LiveKitError(.cancelled, message: "test teardown"))
        // The send fails via .drain, not via the size guard — `.cancelled`
        // confirms the request reached the parked-send queue.
        await #expect {
            try await sendTask.value
        } throws: { ($0 as? LiveKitError)?.type == .cancelled }
    }
}

/// Pins the parser's behavior against each shape of `a=max-message-size`
/// attribute defined by RFC 8841 §6 (SDP for SCTP-based media transport).
@Suite(.tags(.dataChannel))
struct SDPMaxMessageSizeParserTests {
    enum Case: CaseIterable {
        /// Full application section with CRLF line endings — the wire-format
        /// servers actually emit.
        case applicationSectionCRLF
        /// LF-only line endings with surrounding whitespace — exercises tolerant
        /// parsing for peers that don't follow the SDP grammar to the letter.
        case lfOnlyWithSurroundingWhitespace
        /// Attribute absent. Callers fall back to the SDK default cap.
        case missingAttribute
        /// RFC 8841: a value of `0` indicates "no limit". The send guard
        /// downstream honors that by skipping the size check.
        case zeroMeansNoLimit
        /// Non-numeric value — treated as if absent (no fallback parsing).
        case invalidNumericValue
        /// Empty value after the colon — treated as if absent.
        case emptyValue

        var sdp: String {
            switch self {
            case .applicationSectionCRLF:
                "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=sctp-port:5000\r\na=max-message-size:262144\r\n"
            case .lfOnlyWithSurroundingWhitespace:
                "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\n a=max-message-size: 65536 \n"
            case .missingAttribute:
                "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=sctp-port:5000\r\n"
            case .zeroMeansNoLimit:
                "a=max-message-size:0\r\n"
            case .invalidNumericValue:
                "a=max-message-size:abc\r\n"
            case .emptyValue:
                "a=max-message-size:\r\n"
            }
        }

        var expected: UInt64? {
            switch self {
            case .applicationSectionCRLF: 262_144
            case .lfOnlyWithSurroundingWhitespace: 65536
            case .missingAttribute: nil
            case .zeroMeansNoLimit: 0
            case .invalidNumericValue: nil
            case .emptyValue: nil
            }
        }
    }

    @Test(arguments: Case.allCases)
    func parses(_ testCase: Case) {
        #expect(parseSDPMaxMessageSize(testCase.sdp) == testCase.expected)
    }
}
