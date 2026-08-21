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

// There are two layers to leak from, and only one is worth asserting on here.
//
// The *box* is a Swift object, so ARC settles it and a `weak` reference proves
// it deallocated. That is exact — no sampling, no thresholds — and it covers
// the mistake this design is most exposed to: a view quietly pinning the whole
// allocation it was carved out of.
//
// The *fields* are C allocations — the `malloc`/`strdup`/`free` calls in
// NanopbAccessors plus nanopb's own — with no Swift object attached, so ARC
// cannot see them. Measuring those by sampling process heap was tried and
// removed: `malloc_zone_statistics` is process-wide, other suites allocate
// concurrently, and it failed roughly one run in three. Autorelease pools and
// a min-over-rounds estimate got it green locally, but a threshold that
// depends on what else is running is not a test.
//
// The exact version, if that coverage is wanted: `pb.h` explicitly sanctions
// overriding `pb_realloc` / `pb_free`, so routing those and this layer's
// `malloc` through a counted allocator would make the C side countable with no
// sampling at all. That is a production change for a test-only signal, so it
// is deliberately not taken.
@Suite("message ownership")
struct LeakTests {
    @Test("promoting a submessage with owned() lets the parent go")
    func ownedReleasesTheParent() throws {
        // The point of `owned()` is that a view stops pinning the allocation
        // it was carved out of. That only shows up if the promoted value
        // outlives the parent *value* — hold the promotions, drop the parents,
        // and every parent box must be gone.
        let bytes = try LiveKit.Livekit_DataPacket.with {
            $0.user = .with { $0.payload = Data(repeating: 0x22, count: 64) }
        }.serializedBytes()

        var promoted: [LiveKit.Livekit_UserPacket] = []
        var parents: [BoxWatch] = []
        for _ in 0 ..< 100 {
            let decoded = try LiveKit.Livekit_DataPacket(serializedBytes: bytes)
            parents.append(BoxWatch(decoded._owner))
            promoted.append(decoded.user.owned())
        }

        #expect(parents.allSatisfy { !$0.isAlive }, "owned() left the parent pinned")
        #expect(promoted.allSatisfy { $0.payload.count == 64 }, "promoted value lost its storage")
    }

    @Test("a view without owned() does pin its parent")
    func viewPinsTheParent() throws {
        // the other half of the contract, so the test above cannot pass by
        // accident if views stopped retaining parents at all
        let bytes = try LiveKit.Livekit_DataPacket.with {
            $0.user = .with { $0.payload = Data(repeating: 0x33, count: 64) }
        }.serializedBytes()

        var view: LiveKit.Livekit_UserPacket?
        var parent: BoxWatch?
        do {
            let decoded = try LiveKit.Livekit_DataPacket(serializedBytes: bytes)
            parent = BoxWatch(decoded._owner)
            view = decoded.user
        }
        #expect(parent?.isAlive == true, "a live view failed to keep its parent alive")
        #expect(view?.payload.count == 64)
        view = nil
        #expect(parent?.isAlive == false, "dropping the view left the parent alive")
    }
}
