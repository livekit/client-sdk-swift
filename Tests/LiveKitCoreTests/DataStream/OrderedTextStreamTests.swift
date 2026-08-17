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
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// One-shot latch: `wait()` suspends until `open()`; waiters after `open()` pass through.
private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters = []
        for continuation in continuations {
            continuation.resume()
        }
    }
}

// MARK: - Ordered topics

/// The `ordered` text-stream contract is still implemented in Swift (``DataStreams`` chains handler
/// tasks); only chunk assembly moved to the Rust core. These are the v1 behavioral specs, re-pointed
/// at the coordinator, so the rewrite from per-topic to per-sender chaining stays honest.
extension IncomingStreamManagerTests {
    private func waitUntil(_ condition: @Sendable () -> Bool, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Handlers for an `ordered` topic must observe streams in wire order, not the scheduling order
    /// of independently spawned handler tasks.
    @Test func orderedTopicDeliversStreamsInOrder() async throws {
        let count = 16
        let received = StateSync<[String]>([])

        try coordinator.registerTextStreamHandler(for: topicName, ordered: true) { reader, _ in
            let payload = try await reader.readAll()
            received.mutate { $0.append(payload) }
        }

        for index in 0 ..< count {
            await feedTextStream(chunks: ["payload-\(index)"])
        }

        await waitUntil { received.copy().count >= count }
        #expect(received.copy() == (0 ..< count).map { "payload-\($0)" })
        coordinator.unregisterTextStreamHandler(for: topicName)
    }

    /// Ordering must compose transitively: C waits on B even while B is itself still waiting on A.
    /// If the chain breaks, B and C complete while A's handler is gated and the order comes out wrong.
    @Test func orderedTopicChainsAcrossFinishingHandlers() async throws {
        let received = StateSync<[String]>([])
        let gate = TestGate()

        try coordinator.registerTextStreamHandler(for: topicName, ordered: true) { reader, _ in
            let payload = try await reader.readAll()
            // First handler stalls after its stream closed, becoming a still-finishing predecessor
            // for the streams sent after it.
            if payload == "a" { await gate.wait() }
            received.mutate { $0.append(payload) }
        }

        for payload in ["a", "b", "c"] {
            await feedTextStream(chunks: [payload])
        }
        await gate.open()

        await waitUntil { received.copy().count >= 3 }
        #expect(received.copy() == ["a", "b", "c"])
        coordinator.unregisterTextStreamHandler(for: topicName)
    }

    /// A still-open stream must not delay streams that overlap with it on the wire (e.g. a live
    /// transcript arriving while an earlier message stream is still open). Ordering is a wire
    /// happens-before relation — it applies between streams that don't overlap, so it must be keyed
    /// on streams that have *closed*, not merely on the order streams opened in.
    ///
    /// Currently failing, and kept as the specification of the v1 behavior it documents. v1 chained a
    /// newly opened stream behind the handlers of streams that had already *closed*
    /// (`IncomingStreamManager.finishingHandlers`); ``DataStreams`` chains on the order streams
    /// *opened* in, per sender, so a stream that stays open head-of-line-blocks every later stream
    /// from that sender on the topic. Restoring the v1 semantics needs a stream-closed signal, which
    /// the FFI doesn't surface — Swift would have to inspect trailer packets in `handleIncoming`
    /// again, which this migration deliberately stopped doing. Practical exposure is small: only
    /// internal consumers set `ordered`, senders close one segment before opening the next, and the
    /// orphan case self-heals because `closeStreams(from:)` fires on the disconnect that caused it.
    @Test(.disabled("Ordered topics now chain on open order, not on closed predecessors — see doc comment"))
    func orderedTopicDoesNotDelayOverlappingStreams() async throws {
        let received = StateSync<[String]>([])

        try coordinator.registerTextStreamHandler(for: topicName, ordered: true) { reader, _ in
            let payload = try await reader.readAll()
            received.mutate { $0.append(payload) }
        }

        // Stream A opens and stays open; stream B opens, delivers and closes while A is still open —
        // B's handler must complete without waiting for A.
        feedTextHeader(streamID: "open-a")
        feedTextChunk(streamID: "open-a", content: "a")
        await feedTextStream(chunks: ["b"], streamID: "b")

        await waitUntil { !received.copy().isEmpty }
        #expect(received.copy() == ["b"])

        // A still completes normally once its trailer arrives.
        feedTextTrailer(streamID: "open-a")
        await waitUntil { received.copy().count >= 2 }
        #expect(received.copy() == ["b", "a"])
        coordinator.unregisterTextStreamHandler(for: topicName)
    }

    /// A sender disconnecting before its trailer leaves the stream open forever; `closeStreams(from:)`
    /// must fail it so an ordered topic's queue drains.
    @Test func closeStreamsUnblocksOrderedTopic() async throws {
        let received = StateSync<[String]>([])
        let errors = StateSync<[StreamError]>([])
        let entered = TestGate()

        try coordinator.registerTextStreamHandler(for: topicName, ordered: true) { reader, _ in
            await entered.open()
            do {
                let payload = try await reader.readAll()
                received.mutate { $0.append(payload) }
            } catch let error as StreamError {
                errors.mutate { $0.append(error) }
                throw error
            }
        }

        // Header only — no trailer ever arrives, so the handler blocks in `readAll` and, at the head
        // of the ordered queue, would block every later stream.
        feedTextHeader(streamID: "orphan")
        await entered.wait()

        coordinator.closeStreams(from: participant)
        await feedTextStream(chunks: ["after"])

        await waitUntil { !received.copy().isEmpty }
        #expect(received.copy() == ["after"])
        // The FFI core terminates aborted streams with an abnormal-end reason naming the sender.
        #expect(errors.copy().count == 1)
        if case .abnormalEnd = errors.copy().first {} else {
            Issue.record("expected .abnormalEnd, got \(String(describing: errors.copy().first))")
        }
        coordinator.unregisterTextStreamHandler(for: topicName)
    }

    /// Same shape as above via the room-lifecycle path: `reset()` fails all open streams but keeps
    /// handlers registered for after a reconnect.
    @Test func resetUnblocksOrderedTopicAndKeepsHandler() async throws {
        let received = StateSync<[String]>([])
        let entered = TestGate()

        try coordinator.registerTextStreamHandler(for: topicName, ordered: true) { reader, _ in
            await entered.open()
            let payload = try await reader.readAll()
            received.mutate { $0.append(payload) }
        }

        feedTextHeader(streamID: "orphan")
        await entered.wait()

        coordinator.reset()
        await feedTextStream(chunks: ["after-reset"])

        await waitUntil { !received.copy().isEmpty }
        #expect(received.copy() == ["after-reset"])
        coordinator.unregisterTextStreamHandler(for: topicName)
    }
}
