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
// is module-qualified as `LiveKit.Livekit_Room` throughout. Messages are
// immutable: they are built with `.with { }` and derived with `.modifying { }`.
/// Observes whether a box is still alive without contributing a strong
/// reference, which would itself defeat the uniqueness it is checking.
/// Watches a box without retaining it — a strong `let` would keep the box
/// alive and make the very thing under test unobservable. Shared with
/// `LeakTests`; a plain `weak let` local would be neater but needs Swift 6.2.
final class BoxWatch {
    private weak var box: AnyObject?
    var isAlive: Bool { box != nil }
    init(_ box: AnyObject?) { self.box = box }
}

@Suite("nanopb runtime")
struct NanopbRuntimeTests {
    @Test("round-trips scalars, strings and presence")
    func roundTrip() throws {
        let room = LiveKit.Livekit_Room.with { room in
            room.sid = "RM_abc123"
            room.name = "my-room"
            room.metadata = #"{"tier":"pro"}"#
            room.emptyTimeout = 300
            room.maxParticipants = 50
            room.creationTime = 1_754_300_000
            room.activeRecording = true
        }

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

    @Test("`modifying` leaves the original untouched")
    func modifyingIsNonDestructive() {
        let a = LiveKit.Livekit_Room.with { $0.sid = "RM_original" }
        let b = a.modifying { $0.sid = "RM_mutated" }
        #expect(a.sid == "RM_original")
        #expect(b.sid == "RM_mutated")
        #expect(a != b)
    }

    @Test("submessage set and read back")
    func submessage() {
        let empty = LiveKit.Livekit_Room()
        #expect(!empty.hasVersion)

        let room = LiveKit.Livekit_Room.with {
            $0.version = .with { version in
                version.unixMicro = 42
                version.ticks = 7
            }
        }
        #expect(room.hasVersion)
        #expect(room.version.unixMicro == 42)
        #expect(room.version.ticks == 7)
    }

    @Test("assigning a oneof variant from its own storage does not read freed memory")
    func oneofVariantSelfAssignment() {
        // A message variant's getter hands out a view into the union, so the
        // incoming value can point at the allocation the clear is about to
        // free. Same hazard as `submessageSelfAssignment`, one level down.
        let packet = LiveKit.Livekit_DataPacket.with {
            $0.user = .with { $0.payload = Data(repeating: 0xAB, count: 512); $0.topic = "t" }
        }

        let viaVariant = packet.modifying { $0.user = $0.user }
        #expect(viaVariant.user.payload == Data(repeating: 0xAB, count: 512))
        #expect(viaVariant.user.topic == "t")

        let viaProperty = packet.modifying { $0.value = $0.value }
        #expect(viaProperty.user.payload == Data(repeating: 0xAB, count: 512))

        // switching to a different variant sourced from the old one
        let switched = packet.modifying { builder in
            let payload = builder.user.payload
            builder.chatMessage = .with { $0.message = "\(payload.count)" }
        }
        #expect(switched.chatMessage.message == "512")
    }

    @Test("oneof: set, read, switch variant")
    func oneof() throws {
        let ping = LiveKit.Livekit_SignalRequest.with { $0.ping = 99 }
        #expect(ping.message == .ping(99))

        let request = ping.modifying {
            $0.message = .mute(.with { $0.sid = "TR_x"; $0.muted = true })
        }
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
        let info = LiveKit.Livekit_ParticipantInfo.with { info in
            info.attributes = ["role": "speaker", "tier": "pro"]
        }
        let wire = try info.serializedBytes()
        let back = try LiveKit.Livekit_ParticipantInfo(serializedBytes: wire)
        #expect(back.attributes == ["role": "speaker", "tier": "pro"])
    }

    @Test("tolerates unknown fields from a newer server")
    func unknownFields() throws {
        let room = LiveKit.Livekit_Room.with { room in
            room.sid = "RM_fwd"
        }
        let wire = try room.serializedBytes() + [0xF8, 0x7F, 0x01]
        #expect(try LiveKit.Livekit_Room(serializedBytes: wire).sid == "RM_fwd")
    }

    @Test("empty message encodes to zero bytes")
    func emptyMessage() throws {
        #expect(try LiveKit.Livekit_Room().serializedBytes().isEmpty)
    }

    @Test("appended sequence-only packet merges on decode (send-path stamp)")
    func concatenationMerge() throws {
        let packet = LiveKit.Livekit_DataPacket.with { packet in
            packet.user = .with { $0.payload = Data(repeating: 0xAB, count: 1000) }
        }

        // DataChannelPair stamps the reliable sequence by appending a
        // sequence-only packet to the encoded bytes; protobuf defines
        // concatenation as merge, with scalars taking the last occurrence.
        var bytes = try packet.serializedData()
        let stamp = LiveKit.Livekit_DataPacket.with { stamp in
            stamp.sequence = 42
        }
        try bytes.append(stamp.serializedData())

        // the oracle stands in for every receiving SDK's parser
        let oracle = try Livekit_DataPacket(serializedBytes: bytes)
        #expect(oracle.sequence == 42)
        #expect(oracle.user.payload == Data(repeating: 0xAB, count: 1000))

        let back = try LiveKit.Livekit_DataPacket(serializedBytes: bytes)
        #expect(back.sequence == 42)
        #expect(back.user.payload == Data(repeating: 0xAB, count: 1000))
    }

    @Test("an enum value this build does not know survives a round trip")
    func unknownEnumRoundTrips() throws {
        // proto3 enums are open, and `Track.Kind.none` already maps to a value
        // outside the schema — the setter must not drop it, and it has to come
        // back off the wire unchanged rather than collapsing to the zero case.
        let unknown = LiveKit.Livekit_TrackType(rawValue: 10)
        let info = LiveKit.Livekit_TrackInfo.with { $0.type = unknown }
        #expect(info.type.rawValue == 10)

        let back = try LiveKit.Livekit_TrackInfo(serializedBytes: info.serializedBytes())
        #expect(back.type.rawValue == 10)
        #expect(back.type == unknown)
    }

    @Test("modifying a value read from an absent submessage cannot write through the shared box")
    func sharedEmptyIsNeverMutated() {
        // an absent submessage hands out `Storage._emptyBox`, one allocation
        // shared process-wide; `modifying` has to copy off it, or every later
        // reader of any absent submessage of that type sees the mutation
        let absent = LiveKit.Livekit_DataPacket().user
        let derived = absent.modifying { $0.topic = "mutated" }

        #expect(derived.topic == "mutated")
        #expect(LiveKit.Livekit_DataPacket().user.topic.isEmpty)
        #expect(LiveKit.Livekit_UserPacket().topic.isEmpty)
    }

    @Test("owned() frees a view from its parent's allocation")
    func ownedView() {
        let response = LiveKit.Livekit_SignalResponse.with { response in
            response.update = .with { $0.participants = [.with { $0.sid = "PA_x" }] }
        }

        let view = response.update.participants[0]
        let viewSharesParentBox = view._owner === response._owner
        #expect(viewSharesParentBox, "getter should hand out a view")

        let copied = view.owned()
        let copyOwnsItsBox = copied._owner !== response._owner
        #expect(copyOwnsItsBox, "the copy owns its own box")
        #expect(copied == view)

        // a value that already owns its storage is returned as-is
        let alreadyOwned = LiveKit.Livekit_ParticipantInfo.with { $0.sid = "PA_y" }
        let returnedAsIs = alreadyOwned.owned()._owner === alreadyOwned._owner
        #expect(returnedAsIs)
    }

    // `modifying` is consuming: with no other owner it must reuse the box
    // rather than round-trip through encode/decode. Nothing else observes the
    // difference, so without this a regression to always-copy is silent.
    //
    // Box identity has to be watched with a `weak` reference — a strong one
    // would itself make the value non-unique, and comparing `_pointer` can
    // false-pass when malloc hands the fresh box the address just freed.
    @Test("`modifying` reuses the box when nothing else owns it")
    func modifyingIsInPlaceWhenUnique() {
        let packet = LiveKit.Livekit_DataPacket.with {
            $0.user = .with { $0.payload = Data(repeating: 0xAB, count: 4096) }
        }
        let box = BoxWatch(packet._owner)

        // Handing the value to a `consuming` parameter is what real callers
        // such as `Room.send(dataPacket:)` do.
        func stamp(_ packet: consuming LiveKit.Livekit_DataPacket) -> LiveKit.Livekit_DataPacket {
            packet.modifying { $0.participantIdentity = "id" }
        }
        let stamped = stamp(packet)

        #expect(box.isAlive, "unique `modifying` reallocated instead of mutating in place")
        #expect(stamped.participantIdentity == "id")
        #expect(stamped.user.payload.count == 4096)
    }

    @Test("`modifying` copies when the value is still shared")
    func modifyingCopiesWhenShared() {
        let original = LiveKit.Livekit_Room.with { $0.sid = "RM_a" }
        let derived = original.modifying { $0.sid = "RM_b" }
        let boxesDiffer = derived._owner !== original._owner
        #expect(boxesDiffer, "a shared value must not be mutated in place")
        #expect(original.sid == "RM_a")
        #expect(derived.sid == "RM_b")
    }

    // `field.append(x)` is a get-modify-set: the getter hands out views into
    // the field's own array, so the setter is handed values that alias the
    // storage it is about to release. Freeing first read from freed memory —
    // it crashed MetricsManager's stats path once copy-on-write stopped
    // reallocating on every setter call and masking it.
    @Test("appending to a repeated submessage field does not read freed storage")
    func repeatedAppendAliasesItsOwnStorage() throws {
        let batch = LiveKit.Livekit_MetricsBatch.with { batch in
            for index in 0 ..< 32 {
                batch.timeSeries.append(.with {
                    $0.label = UInt32(index)
                    $0.samples = [.with { $0.value = Float(index) }]
                })
            }
            batch.strData = ["a", "b"]
        }

        #expect(batch.timeSeries.count == 32)
        #expect(batch.timeSeries[31].label == 31)
        #expect(batch.timeSeries[31].samples.first?.value == 31)

        // the oracle stands in for the receiving side
        let oracle = try Livekit_MetricsBatch(serializedBytes: batch.serializedBytes())
        #expect(oracle.timeSeries.count == 32)
        #expect(oracle.timeSeries[31].label == 31)
    }

    @Test("assigning a submessage field from itself does not read freed storage")
    func submessageSelfAssignment() {
        let room = LiveKit.Livekit_Room.with { room in
            room.version = .with { $0.unixMicro = 99 }
            room.version = room.version // aliases the slot being replaced
            room.sid = "RM_alias"
        }
        #expect(room.version.unixMicro == 99)
        #expect(room.sid == "RM_alias")
    }
}
