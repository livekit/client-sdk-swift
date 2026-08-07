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

import Darwin
import Foundation
@testable import LiveKit
import Testing

// Every setter in this layer frees one allocation and makes another, and
// `NanopbBox.deinit` is the only thing that frees a message's tree. Nothing
// else checks that: TSan finds races, the fuzzer finds crashes, and ASan on
// Darwin does not ship LeakSanitizer, so a setter that stopped freeing would
// pass the entire suite.
//
// These churn one operation many times and compare live heap before and after.
//
// `malloc_zone_statistics` is process-wide, so the sample also sees whatever
// other suites have live at that instant. `.serialized` removes the
// interference within this suite, and the threshold is set well above
// cross-suite noise: a leak of ~1 KB per iteration shows up as ~2 MB, verified
// by deleting a `free` and watching every test here fail by 1.7–2.5 MB.
@Suite("nanopb leaks", .serialized)
struct LeakTests {
    private static let iterations = 2000
    private static let rounds = 3
    /// Well above per-round noise, well below the ~2 MB a real leak produces.
    private static let tolerance = 512 * 1024

    private static func liveBytes() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &stats)
        return Int(stats.size_in_use)
    }

    /// Measures heap growth across `iterations` runs of `body`, and reports the
    /// smallest growth seen over several rounds.
    ///
    /// Two sources of false positives to defeat. `Data` and `String` can park
    /// objects in an autorelease pool that drains later, so each round runs
    /// inside its own pool. And the counter is process-wide, so a round can
    /// catch another suite mid-allocation — that noise varies per round while a
    /// real leak recurs in every one, so the minimum is the honest estimate.
    private static func churn(_ label: String, _ body: () throws -> Void) rethrows {
        try autoreleasepool { try body() } // settle one-time allocations

        var smallest = Int.max
        for _ in 0 ..< rounds {
            let growth = try autoreleasepool { () throws -> Int in
                let before = liveBytes()
                for _ in 0 ..< iterations {
                    try body()
                }
                return liveBytes() - before
            }
            smallest = min(smallest, growth)
            if smallest < tolerance { break } // already conclusive
        }
        #expect(
            smallest < tolerance,
            "\(label) grew the heap by \(smallest) bytes over \(iterations) iterations",
        )
    }

    @Test("replacing a string field frees the old allocation")
    func stringReplacement() {
        let payload = String(repeating: "x", count: 1024)
        Self.churn("string replacement") {
            _ = LiveKit.Livekit_ParticipantInfo.with {
                $0.metadata = payload
                $0.metadata = payload // second write must free the first
                $0.identity = payload
            }
        }
    }

    @Test("replacing a bytes field frees the old allocation")
    func bytesReplacement() {
        let payload = Data(repeating: 0xAB, count: 1024)
        Self.churn("bytes replacement") {
            _ = LiveKit.Livekit_UserPacket.with {
                $0.payload = payload
                $0.payload = payload
            }
        }
    }

    @Test("switching oneof variants releases the previous payload")
    func oneofSwitching() {
        let payload = Data(repeating: 0xCD, count: 1024)
        let text = String(repeating: "y", count: 512)
        Self.churn("oneof switching") {
            _ = LiveKit.Livekit_DataPacket.with {
                // each write releases the previous variant, which has a
                // different layout — the descriptor has to match the *old* one
                $0.user = .with { $0.payload = payload }
                $0.chatMessage = .with { $0.message = text }
                $0.sipDtmf = .with { $0.digit = text }
                $0.user = .with { $0.payload = payload }
            }
        }
    }

    @Test("replacing a repeated submessage field frees the old array")
    func repeatedMessageReplacement() {
        let layers = (0 ..< 8).map { index in
            LiveKit.Livekit_VideoLayer.with { $0.width = UInt32(index); $0.height = UInt32(index) }
        }
        Self.churn("repeated submessage replacement") {
            _ = LiveKit.Livekit_TrackInfo.with {
                $0.layers = layers
                $0.layers = layers
            }
        }
    }

    @Test("appending to a repeated field through its own getter does not leak")
    func repeatedSelfAppend() {
        // the aliasing case the setter copies-before-releasing for
        Self.churn("repeated self-append") {
            var info = LiveKit.Livekit_TrackInfo.with {
                $0.layers = [.with { $0.width = 1 }]
            }
            for _ in 0 ..< 4 {
                info = info.modifying { $0.layers += $0.layers }
            }
        }
    }

    @Test("decoding then dropping a message releases its whole tree")
    func decodeLifecycle() throws {
        let bytes = try LiveKit.Livekit_DataPacket.with {
            $0.participantIdentity = String(repeating: "p", count: 256)
            $0.destinationIdentities = (0 ..< 8).map { "identity-\($0)" }
            $0.user = .with {
                $0.payload = Data(repeating: 0xEF, count: 1024)
                $0.topic = String(repeating: "t", count: 256)
            }
        }.serializedBytes()

        try Self.churn("decode lifecycle") {
            let packet = try LiveKit.Livekit_DataPacket(serializedBytes: bytes)
            _ = packet.user.payload.count
            _ = packet.destinationIdentities.count
        }
    }

    @Test("copying out of a parent with owned() does not retain the parent")
    func ownedCopy() throws {
        let bytes = try LiveKit.Livekit_DataPacket.with {
            $0.user = .with { $0.payload = Data(repeating: 0x11, count: 2048) }
        }.serializedBytes()

        try Self.churn("owned copy") {
            let packet = try LiveKit.Livekit_DataPacket(serializedBytes: bytes)
            _ = packet.user.owned()
        }
    }
}
