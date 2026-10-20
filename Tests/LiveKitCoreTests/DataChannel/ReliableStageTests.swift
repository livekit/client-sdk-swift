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

/// Pins ``ReliableStage``'s sequence stamping and replay set, which the drain drives but does not
/// own. Exercised directly: no channel is involved in either.
@Suite(.tags(.dataChannel))
struct ReliableStageTests {
    private static let retryFloor: UInt64 = 1024

    private func write(_ sequence: UInt32, byteCount: Int = 16) -> ReadyWrite {
        ReadyWrite(payload: Data(repeating: 0xAB, count: byteCount), sequence: sequence)
    }

    /// Dispatches `count` packets through the stage and returns the sequences it stamped.
    private func dispatch(_ count: Int, through stage: inout ReliableStage) throws -> [UInt32] {
        var stamped: [UInt32] = []
        for _ in 0 ..< count {
            var prepared: [PreparedBytes] = []
            try stage.prepare(Livekit_DataPacket(), into: &prepared)
            let sequence = try #require(prepared.first?.sequence)
            stamped.append(sequence)
            stage.didDispatch(write(sequence))
        }
        return stamped
    }

    private func replaySequences(after lastSequence: UInt32, from stage: inout ReliableStage) -> [UInt32] {
        var replayed: [UInt32] = []
        stage.handle(.replay(after: lastSequence)) { replayed.append($0.sequence) }
        return replayed
    }

    @Test func stampsConsecutiveSequencesFromOne() throws {
        var stage = ReliableStage(retryFloor: Self.retryFloor)
        #expect(try dispatch(3, through: &stage) == [1, 2, 3])
    }

    /// An already-stamped packet keeps its sequence — the counter is only for packets that arrive
    /// unstamped.
    @Test func preservesAnExistingSequence() throws {
        var stage = ReliableStage(retryFloor: Self.retryFloor)
        var prepared: [PreparedBytes] = []
        try stage.prepare(Livekit_DataPacket.with { $0.sequence = 42 }, into: &prepared)
        #expect(prepared.first?.sequence == 42)
    }

    /// The wire bytes, not just the returned sequence: the stamp is a second encoded message
    /// appended to the first, and the pair must decode to the original packet carrying it.
    @Test(.bug("https://github.com/livekit/client-sdk-swift/issues/1158"))
    func stampedBytesDecodeToThePacketWithItsSequence() throws {
        var stage = ReliableStage(retryFloor: Self.retryFloor)
        let payload = Data(String(repeating: #"{"type":"chat","text":"hello"}"#, count: 10).utf8)
        var prepared: [PreparedBytes] = []
        try stage.prepare(Livekit_DataPacket.with {
            $0.kind = .reliable
            $0.user = Livekit_UserPacket.with { $0.payload = payload }
        }, into: &prepared)

        let bytes = try #require(prepared.first).bytes
        let decoded = try Livekit_DataPacket(serializedData: bytes)
        let sequence = decoded.sequence
        let kind = decoded.kind
        let decodedPayload = decoded.user.payload
        #expect(sequence == 1)
        #expect(kind == .reliable)
        #expect(decodedPayload == payload)
    }

    @Test func replaysOnlyWhatFollowsTheAcknowledgedSequence() throws {
        var stage = ReliableStage(retryFloor: Self.retryFloor)
        _ = try dispatch(4, through: &stage)
        #expect(replaySequences(after: 2, from: &stage) == [3, 4])
    }

    /// The regression this suite exists for: the sequence restarting at 1 while writes stamped 1…N
    /// stay retained would replay stale sequences into a session that never saw them.
    @Test func resetClearsTheReplaySetAlongWithTheSequence() throws {
        var stage = ReliableStage(retryFloor: Self.retryFloor)
        _ = try dispatch(3, through: &stage)

        stage.reset()

        #expect(replaySequences(after: 0, from: &stage).isEmpty, "retained writes outlived their session")
        #expect(try dispatch(1, through: &stage) == [1], "the sequence restarts")
    }

    /// A resume is the one moment the replay set matters, so nothing about handling one discards it
    /// beyond what was acknowledged.
    @Test func replaySurvivesUntilAcknowledged() throws {
        var stage = ReliableStage(retryFloor: Self.retryFloor)
        _ = try dispatch(3, through: &stage)
        #expect(replaySequences(after: 0, from: &stage) == [1, 2, 3])
    }
}
