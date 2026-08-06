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

/// Validates the immutability invariant behind `NanopbBox`'s
/// `@unchecked Sendable`: values sharing a box may be read concurrently, and
/// `modifying` writes in place only when nothing else can observe the storage.
/// Run under TSan (`swift test --sanitize=thread`) to catch any generated
/// accessor that mutates storage another value can reach.
@Suite("nanopb concurrency")
struct ConcurrencyStressTests {
    private static func makeBase() -> LiveKit.Livekit_Room {
        LiveKit.Livekit_Room.with { room in
            room.sid = "RM_stress"
            room.name = "stress-room"
            room.metadata = String(repeating: "x", count: 512)
            room.emptyTimeout = 300
            room.version = .with { $0.unixMicro = 42 }
        }
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
    func concurrentModifying() async {
        let base = Self.makeBase()
        await withTaskGroup(of: Bool.self) { group in
            for worker in 0 ..< 8 {
                group.addTask {
                    var ok = true
                    for iteration in 0 ..< 500 {
                        let copy = base.modifying { copy in
                            copy.sid = "RM_\(worker)_\(iteration)"
                            copy.emptyTimeout = UInt32(worker)
                            copy.version = .with { $0.ticks = Int32(iteration) }
                        }
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

    @Test("views keep the parent allocation alive after the parent value dies")
    func viewLifetime() async {
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    var ok = true
                    for iteration in 0 ..< 300 {
                        let view: LiveKit.Livekit_ParticipantInfo = {
                            let response = LiveKit.Livekit_SignalResponse.with { response in
                                response.update = .with { $0.participants = [.with { $0.sid = "PA_\(iteration)" }] }
                            }
                            return response.update.participants[0]
                        }() // the response dies here; the view must hold the box
                        ok = ok && view.sid == "PA_\(iteration)"
                        let copied = view.owned()
                        ok = ok && copied.sid == "PA_\(iteration)"
                    }
                    return ok
                }
            }
            for await ok in group {
                #expect(ok)
            }
        }
    }

    @Test("shared views stay stable while sibling copies mutate and detach")
    func viewStabilityUnderCopyMutation() async {
        let response = LiveKit.Livekit_SignalResponse.with { response in
            response.update = .with {
                $0.participants = [
                    .with { $0.sid = "PA_a"; $0.name = "alice" },
                    .with { $0.sid = "PA_b"; $0.name = "bob" },
                ]
            }
        }
        let views = response.update.participants // zero-copy views into `response`
        let shared = response

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 4 { // readers: views must never observe mutation
                group.addTask {
                    var ok = true
                    for _ in 0 ..< 1000 {
                        ok = ok && views[0].sid == "PA_a" && views[1].name == "bob"
                    }
                    return ok
                }
            }
            for worker in 0 ..< 4 { // writers: `modifying` must copy, never touch the shared box
                group.addTask {
                    var ok = true
                    for iteration in 0 ..< 250 {
                        let copy = shared.modifying { copy in
                            copy.update = .with { $0.participants = [.with { $0.sid = "PA_\(worker)_\(iteration)" }] }
                        }
                        ok = ok && copy.update.participants.count == 1
                    }
                    return ok
                }
            }
            for await ok in group {
                #expect(ok)
            }
        }
        #expect(response.update.participants.count == 2)
    }

    @Test("oneof variant churn on concurrent copies")
    func oneofChurn() async {
        let base = LiveKit.Livekit_SignalRequest.with { base in
            base.ping = 1
        }
        let shared = base

        await withTaskGroup(of: Bool.self) { group in
            for worker in 0 ..< 8 {
                group.addTask {
                    var ok = true
                    for iteration in 0 ..< 250 {
                        // cycle variants: scalar → message → scalar (exercises
                        // union release + zeroing on every switch)
                        let copy = shared.modifying { copy in
                            copy.mute = .with { $0.sid = "TR_\(worker)"; $0.muted = true }
                            copy.ping = Int64(iteration)
                            copy.offer = .with { $0.sdp = "sdp_\(iteration)" }
                        }
                        let wire = (try? copy.serializedBytes()) ?? []
                        let back = try? LiveKit.Livekit_SignalRequest(serializedBytes: wire)
                        ok = ok && back?.offer.sdp == "sdp_\(iteration)"
                    }
                    return ok
                }
            }
            for await ok in group {
                #expect(ok)
            }
        }
        #expect(shared.ping == 1)
    }

    @Test("map and repeated churn on concurrent copies")
    func collectionChurn() async {
        let base = LiveKit.Livekit_ParticipantInfo.with { base in
            base.attributes = ["role": "listener"]
            base.tracks = [.with { $0.sid = "TR_base" }]
        }
        let shared = base

        await withTaskGroup(of: Bool.self) { group in
            for worker in 0 ..< 8 {
                group.addTask {
                    var ok = true
                    for iteration in 0 ..< 200 {
                        let copy = shared.modifying { copy in
                            copy.attributes = ["worker": "\(worker)", "iteration": "\(iteration)"]
                            copy.tracks = [
                                .with { $0.sid = "TR_\(worker)_\(iteration)" },
                                .with { $0.sid = "TR_second" },
                            ]
                        }
                        // equality reads shared storage while other tasks detach
                        ok = ok && copy != shared
                        ok = ok && copy.tracks.count == 2
                    }
                    return ok
                }
            }
            for await ok in group {
                #expect(ok)
            }
        }
        #expect(shared.attributes == ["role": "listener"])
        #expect(shared.tracks.count == 1)
    }
}
