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

/// Cross-checks the nanopb facades against protoc-gen-swift on the same protos.
/// Two independent implementations must agree byte-for-byte, in both directions.
///
/// `Livekit_Room` here is the oracle's type (compiled into this test target);
/// the nanopb one is module-qualified as `LiveKit.Livekit_Room`.
@Suite("wire conformance vs SwiftProtobuf")
struct ConformanceTests {
    @Test("nanopb output decodes in SwiftProtobuf")
    func nanopbToSwiftProtobuf() throws {
        var room = LiveKit.Livekit_Room()
        room.sid = "RM_conformance"
        room.name = "room-name"
        room.metadata = #"{"k":"v"}"#
        room.emptyTimeout = 600
        room.maxParticipants = 12
        room.creationTime = 1_754_300_777
        room.activeRecording = true

        let bytes = try room.serializedBytes()
        let oracle = try Livekit_Room(serializedBytes: bytes)

        #expect(oracle.sid == "RM_conformance")
        #expect(oracle.name == "room-name")
        #expect(oracle.metadata == #"{"k":"v"}"#)
        #expect(oracle.emptyTimeout == 600)
        #expect(oracle.maxParticipants == 12)
        #expect(oracle.creationTime == 1_754_300_777)
        #expect(oracle.activeRecording == true)
    }

    @Test("SwiftProtobuf output decodes in nanopb")
    func swiftProtobufToNanopb() throws {
        var oracle = Livekit_Room()
        oracle.sid = "RM_reverse"
        oracle.name = "reverse"
        oracle.emptyTimeout = 99
        oracle.activeRecording = false
        oracle.creationTime = -5

        let bytes: [UInt8] = try oracle.serializedBytes()
        let room = try LiveKit.Livekit_Room(serializedBytes: bytes)

        #expect(room.sid == "RM_reverse")
        #expect(room.name == "reverse")
        #expect(room.emptyTimeout == 99)
        #expect(room.creationTime == -5)
    }

    @Test("both implementations produce identical bytes")
    func identicalEncoding() throws {
        var room = LiveKit.Livekit_Room()
        room.sid = "RM_same"
        room.emptyTimeout = 7
        room.creationTime = 1_700_000_000

        var oracle = Livekit_Room()
        oracle.sid = "RM_same"
        oracle.emptyTimeout = 7
        oracle.creationTime = 1_700_000_000

        let mine = try room.serializedBytes()
        let theirs: [UInt8] = try oracle.serializedBytes()
        #expect(mine == theirs)
    }

    @Test("empty and unicode strings survive both directions")
    func edgeCases() throws {
        var room = LiveKit.Livekit_Room()
        room.sid = ""
        room.name = "🎙 café — ünïcode"
        let bytes = try room.serializedBytes()

        let oracle = try Livekit_Room(serializedBytes: bytes)
        #expect(oracle.name == "🎙 café — ünïcode")

        let back = try LiveKit.Livekit_Room(serializedBytes: bytes)
        #expect(back.name == "🎙 café — ünïcode")
    }
}
