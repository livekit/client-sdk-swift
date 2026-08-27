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

// `Livekit_DataPacket` is decoded straight from bytes another participant
// sent, so the decoder is the SDK's only parser facing untrusted input. These
// walk mutated encodings through it looking for a crash, a hang, or a value
// that cannot be re-encoded; the seed is fixed so a failure is reproducible.
//
// Byte-for-byte agreement with the oracle is deliberately *not* asserted:
// nanopb drops unknown fields and encodes explicitly-set zero scalars, both
// pinned in ConformanceEdgeCaseTests.
@Suite("decode fuzzing")
struct DecodeFuzzTests {
    /// xorshift64*, so a failing case can be replayed from its seed alone.
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 2_685_821_657_736_338_717
        }

        mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
        mutating func index(_ upperBound: Int) -> Int {
            upperBound <= 0 ? 0 : Int(next() % UInt64(upperBound))
        }
    }

    private static func seedCorpus() throws -> [[UInt8]] {
        try [
            LiveKit.Livekit_DataPacket.with {
                $0.kind = .reliable
                $0.participantIdentity = "PA_fuzz"
                $0.user = .with { $0.payload = Data(repeating: 0xAB, count: 64) }
            },
            LiveKit.Livekit_DataPacket.with {
                $0.sequence = 7
                $0.streamHeader = .with { $0.streamID = "S1"; $0.topic = "t" }
            },
            LiveKit.Livekit_DataPacket.with {
                $0.rpcRequest = .with { $0.id = "1"; $0.method = "m"; $0.payload = "{}" }
            },
        ].map { try $0.serializedBytes() }
    }

    @Test("mutated packets never crash the decoder and always re-encode")
    func mutatedPacketsSurviveDecode() throws {
        var rng = Rng(state: 0x5DEE_CE66_D1CE_B00C)
        let corpus = try Self.seedCorpus()

        for iteration in 0 ..< 20000 {
            var bytes = corpus[rng.index(corpus.count)]
            switch rng.next() % 4 {
            case 0: // flip a byte
                if !bytes.isEmpty { bytes[rng.index(bytes.count)] = rng.byte() }
            case 1: // truncate — exercises short-buffer paths
                bytes.removeLast(rng.index(bytes.count))
            case 2: // append junk, including bogus tags and lengths
                bytes.append(contentsOf: (0 ..< rng.index(8)).map { _ in rng.byte() })
            default: // splice two encodings (protobuf concatenation is merge)
                bytes += corpus[rng.index(corpus.count)]
            }

            // The property under test is that a hostile packet cannot take the
            // process down: decoding either throws or yields a usable value.
            guard let packet = try? LiveKit.Livekit_DataPacket(serializedBytes: bytes) else { continue }

            // reading every field shape must not read out of bounds
            _ = packet.participantIdentity
            _ = packet.sequence
            _ = packet.destinationIdentities
            _ = packet.user.payload
            _ = packet.value

            let reencoded = try packet.serializedBytes()
            let again = try LiveKit.Livekit_DataPacket(serializedBytes: reencoded)
            #expect(try again.serializedBytes() == reencoded,
                    "decode/encode not idempotent at iteration \(iteration)")
        }
    }

    @Test("random bytes are rejected or decoded, never fatal")
    func randomBytesSurviveDecode() throws {
        var rng = Rng(state: 0x0BAD_C0FF_EE0D_D00D)

        for _ in 0 ..< 20000 {
            let bytes = (0 ..< rng.index(64)).map { _ in rng.byte() }
            guard let packet = try? LiveKit.Livekit_DataPacket(serializedBytes: bytes) else { continue }
            _ = packet.value
            _ = try packet.serializedBytes()
        }
    }

    @Test("deeply nested submessages do not exhaust the stack")
    func deepNestingIsBounded() throws {
        // The SDK's schema has no self-recursive message, so nesting depth is
        // bounded by the schema — but a hostile packet can still claim deep
        // nesting through repeated length-delimited headers.
        var bytes = try LiveKit.Livekit_DataPacket.with {
            $0.user = .with { $0.payload = Data(repeating: 0x01, count: 8) }
        }.serializedBytes()

        for _ in 0 ..< 2000 {
            // wrap in another length-delimited field 1 record
            var wrapped: [UInt8] = [0x0A]
            var length = UInt64(bytes.count)
            while length >= 0x80 {
                wrapped.append(UInt8(length & 0x7F) | 0x80)
                length >>= 7
            }
            wrapped.append(UInt8(length))
            bytes = wrapped + bytes
        }

        _ = try? LiveKit.Livekit_DataPacket(serializedBytes: bytes)
    }
}
