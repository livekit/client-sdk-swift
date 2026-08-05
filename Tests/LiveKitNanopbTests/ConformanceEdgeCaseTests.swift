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
import LiveKitNanopb
import SwiftProtobuf
import Testing

/// Pins the known semantic differences between the nanopb facades and
/// SwiftProtobuf, so a behavior change here is a deliberate decision rather
/// than an accident. Wire *compatibility* is covered by the exemplar suite;
/// these are the corners where the two implementations legitimately diverge.
@Suite("conformance edge cases")
struct ConformanceEdgeCaseTests {
    // MARK: presence

    /// FT_POINTER presence is the pointer, not the value: a scalar explicitly
    /// set to 0 encodes as an explicit zero field, where proto3 SwiftProtobuf
    /// emits nothing. Any proto3 receiver decodes both to the same message.
    @Test("scalar set to zero emits an explicit field, unlike SwiftProtobuf")
    func zeroScalarPresence() throws {
        var facade = LiveKit.Livekit_Room()
        facade.emptyTimeout = 0
        let facadeBytes = try facade.serializedData()

        var oracle = Livekit_Room()
        oracle.emptyTimeout = 0
        let oracleBytes = try oracle.serializedData()

        #expect(oracleBytes.isEmpty)
        #expect(!facadeBytes.isEmpty)

        // semantically identical to any receiver
        let decoded = try Livekit_Room(serializedBytes: facadeBytes)
        #expect(decoded == Livekit_Room())

        // corollary of bytes-based equality: explicit zero != untouched default
        #expect(facade != LiveKit.Livekit_Room())
    }

    // MARK: strings

    /// nanopb stores FT_POINTER strings NUL-terminated, so an embedded NUL
    /// (legal UTF-8, and user-controlled metadata can carry it) truncates at
    /// set-time. SwiftProtobuf round-trips it. Signaling fields are sids,
    /// names, and JSON — if a field ever needs NUL-safe payloads, it must be
    /// `bytes`, not `string`.
    @Test("string with embedded NUL truncates, unlike SwiftProtobuf")
    func embeddedNulTruncates() throws {
        var facade = LiveKit.Livekit_Room()
        facade.name = "a\0b"
        #expect(facade.name == "a")

        var oracle = Livekit_Room()
        oracle.name = "a\0b"
        let roundTripped = try Livekit_Room(serializedBytes: oracle.serializedData())
        #expect(roundTripped.name == "a\0b")
    }

    // MARK: large payloads

    /// pb_size_t must be 32-bit (PB_FIELD_32BIT in the vendored pb.h) or any
    /// bytes field over 65535 traps — the pre-connect audio buffer case.
    /// lk_abi_check.c guards the define at compile time; this proves it at
    /// runtime and would catch a regression to the 16-bit default.
    @Test("bytes fields beyond 16-bit sizes round-trip")
    func largeBytesField() throws {
        var facade = LiveKit.Livekit_UserPacket()
        facade.payload = Data(repeating: 0xAB, count: 100_000)
        let bytes = try facade.serializedData()

        let oracle = try Livekit_UserPacket(serializedBytes: bytes)
        #expect(oracle.payload.count == 100_000)

        let back = try LiveKit.Livekit_UserPacket(serializedData: oracle.serializedData())
        #expect(back.payload == facade.payload)
    }

    // MARK: maps

    /// Multi-entry maps cannot be compared byte-for-byte (SwiftProtobuf entry
    /// order is undefined; ours is sorted) — equivalence is semantic, in both
    /// directions.
    @Test("multi-entry maps are order-independent across implementations")
    func multiEntryMap() throws {
        let entries = ["k1": "v1", "k2": "v2", "k3": "v3"]

        var facade = LiveKit.Livekit_ParticipantInfo()
        facade.attributes = entries
        let decodedOracle = try Livekit_ParticipantInfo(serializedBytes: facade.serializedData())
        #expect(decodedOracle.attributes == entries)

        var oracle = Livekit_ParticipantInfo()
        oracle.attributes = entries
        let decodedFacade = try LiveKit.Livekit_ParticipantInfo(serializedData: oracle.serializedData())
        #expect(decodedFacade.attributes == entries)
    }

    // MARK: unknown fields

    /// nanopb has no unknown-field retention: fields a newer peer sends that
    /// this SDK's protos don't know are dropped on re-encode, where
    /// SwiftProtobuf preserved them. Relevant only to echo paths (e.g.
    /// sendSyncState); pinned here so the difference stays deliberate.
    @Test("unknown fields are dropped on re-encode, unlike SwiftProtobuf")
    func unknownFieldsDropped() throws {
        var room = Livekit_Room()
        room.sid = "RM_x"
        let known = try room.serializedData()

        // append an unknown varint field #2047: tag (2047 << 3) = [0xF8, 0x7F]
        let unknown = known + Data([0xF8, 0x7F, 0x01])

        let oracleEcho = try Livekit_Room(serializedBytes: unknown).serializedData()
        #expect(oracleEcho == unknown)

        let facadeEcho = try LiveKit.Livekit_Room(serializedData: unknown).serializedData()
        #expect(facadeEcho == known)
    }
}
