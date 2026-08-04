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

/// Validates the copy-on-write invariant behind `NanopbBox`'s
/// `@unchecked Sendable`: values sharing a box may be read concurrently, and
/// mutation always detaches. Run under TSan (`swift test --sanitize=thread`)
/// to catch any generated accessor that mutates shared storage in place.
@Suite("nanopb CoW concurrency")
struct ConcurrencyStressTests {
    private static func makeBase() -> LiveKit.Livekit_Room {
        var room = LiveKit.Livekit_Room()
        room.sid = "RM_stress"
        room.name = "stress-room"
        room.metadata = String(repeating: "x", count: 512)
        room.emptyTimeout = 300
        room.version.unixMicro = 42
        return room
    }

    @Test("concurrent reads of one shared value")
    func sharedReads() async {
        let base = Self.makeBase()
        await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    var checksum = 0
                    for _ in 0 ..< 2000 {
                        checksum &+= base.sid.utf8.count &+ Int(base.emptyTimeout)
                        checksum &+= base.version.unixMicro > 0 ? 1 : 0
                        checksum &+= (try? base.serializedBytes().count) ?? 0
                    }
                    return checksum
                }
            }
            var results: Set<Int> = []
            for await value in group {
                results.insert(value)
            }
            #expect(results.count == 1) // identical work, identical checksum
        }
    }

    @Test("concurrent mutation of independent copies never affects the shared base")
    func copyOnWriteDetach() async {
        let base = Self.makeBase()
        await withTaskGroup(of: Bool.self) { group in
            for worker in 0 ..< 8 {
                group.addTask {
                    var ok = true
                    for iteration in 0 ..< 500 {
                        var copy = base // shares the box until first mutation
                        copy.sid = "RM_\(worker)_\(iteration)"
                        copy.emptyTimeout = UInt32(worker)
                        copy.version.ticks = Int32(iteration)
                        ok = ok && copy.sid == "RM_\(worker)_\(iteration)"
                    }
                    return ok
                }
            }
            for await ok in group {
                #expect(ok)
            }
        }
        #expect(base.sid == "RM_stress")
        #expect(base.emptyTimeout == 300)
        #expect(base.version.ticks == 0)
    }
}
