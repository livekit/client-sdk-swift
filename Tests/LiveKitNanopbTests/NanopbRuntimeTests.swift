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

// The oracle target compiles its own `Livekit_Room`, so the nanopb-backed type
// is module-qualified as `LiveKit.Livekit_Room` throughout.
@Suite("nanopb CoW runtime")
struct NanopbRuntimeTests {
    @Test("round-trips scalars, strings and presence")
    func roundTrip() throws {
        var room = LiveKit.Livekit_Room()
        room.sid = "RM_abc123"
        room.name = "my-room"
        room.metadata = #"{"tier":"pro"}"#
        room.emptyTimeout = 300
        room.maxParticipants = 50
        room.creationTime = 1_754_300_000
        room.activeRecording = true

        let wire = try room.serializedBytes()
        let back = try LiveKit.Livekit_Room(serializedBytes: wire)

        #expect(back.sid == "RM_abc123")
        #expect(back.name == "my-room")
        #expect(back.metadata == #"{"tier":"pro"}"#)
        #expect(back.emptyTimeout == 300)
        #expect(back.maxParticipants == 50)
        #expect(back.creationTime == 1_754_300_000)
        #expect(back.activeRecording == true)
        #expect(try back.serializedBytes() == wire)
        #expect(back == room)
    }

    @Test("copies have value semantics (copy-on-write)")
    func valueSemantics() {
        var a = LiveKit.Livekit_Room()
        a.sid = "RM_original"
        let b = a
        a.sid = "RM_mutated"
        #expect(b.sid == "RM_original")
        #expect(a.sid == "RM_mutated")
        #expect(a != b)
    }

    @Test("submessage get-modify-set round trip")
    func submessage() {
        var room = LiveKit.Livekit_Room()
        #expect(!room.hasVersion)
        room.version.unixMicro = 42
        room.version.ticks = 7
        #expect(room.hasVersion)
        #expect(room.version.unixMicro == 42)
        #expect(room.version.ticks == 7)
    }

    @Test("oneof: set, read, switch variant")
    func oneof() throws {
        var request = LiveKit.Livekit_SignalRequest()
        request.ping = 99
        #expect(request.message == .ping(99))

        request.message = .mute(.with { $0.sid = "TR_x"; $0.muted = true })
        guard case let .mute(mute) = request.message else {
            Issue.record("expected .mute")
            return
        }
        #expect(mute.sid == "TR_x")
        #expect(mute.muted == true)

        let wire = try request.serializedBytes()
        // oracle cross-check localises encode vs decode bugs
        let oracle = try Livekit_SignalRequest(serializedBytes: wire)
        #expect(oracle.mute.sid == "TR_x")
        let back = try LiveKit.Livekit_SignalRequest(serializedBytes: wire)
        #expect(back.mute.sid == "TR_x")
    }

    @Test("map fields round trip as dictionaries")
    func maps() throws {
        var info = LiveKit.Livekit_ParticipantInfo()
        info.attributes = ["role": "speaker", "tier": "pro"]
        let wire = try info.serializedBytes()
        let back = try LiveKit.Livekit_ParticipantInfo(serializedBytes: wire)
        #expect(back.attributes == ["role": "speaker", "tier": "pro"])
    }

    @Test("tolerates unknown fields from a newer server")
    func unknownFields() throws {
        var room = LiveKit.Livekit_Room()
        room.sid = "RM_fwd"
        let wire = try room.serializedBytes() + [0xF8, 0x7F, 0x01]
        #expect(try LiveKit.Livekit_Room(serializedBytes: wire).sid == "RM_fwd")
    }

    @Test("empty message encodes to zero bytes")
    func emptyMessage() throws {
        #expect(try LiveKit.Livekit_Room().serializedBytes().isEmpty)
    }
}
