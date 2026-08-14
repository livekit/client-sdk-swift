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

/// A sink that rejects on demand, so the queue-full policy can be observed without saturating a
/// live pipeline (which would make the outcome depend on how fast the SFU drains).
private final class RecordingSink: DataTrackFrameSink, @unchecked Sendable {
    /// Frames handed to `tryPush`, rejected ones included.
    let offered = StateSync<[DataTrackFrame]>([])
    /// Frames the sink accepted.
    let accepted = StateSync<[DataTrackFrame]>([])

    private let _isPublished = StateSync<Bool>(true)
    /// Rejects every frame whose payload matches, as though the queue were full.
    private let reject: @Sendable (DataTrackFrame) -> Bool
    /// Unpublishes once this many frames have been accepted, mid-send and without a race.
    private let unpublishAfter: Int?

    init(isPublished: Bool = true,
         unpublishAfter: Int? = nil,
         reject: @escaping @Sendable (DataTrackFrame) -> Bool = { _ in false })
    {
        _isPublished.mutate { $0 = isPublished }
        self.unpublishAfter = unpublishAfter
        self.reject = reject
    }

    var isPublished: Bool { _isPublished.copy() }

    func tryPush(frame: DataTrackFrame) throws {
        offered.mutate { $0.append(frame) }
        guard !reject(frame) else {
            throw DataTrackPushFrameError.queueFull("The send queue is full", frame: frame)
        }
        let count = accepted.mutate { accepted in
            accepted.append(frame)
            return accepted.count
        }
        if let unpublishAfter, count >= unpublishAfter {
            _isPublished.mutate { $0 = false }
        }
    }
}

/// `send(contentsOf:)`'s behavior when the queue rejects a frame or the track goes away.
@Suite(.tags(.dataTrack))
struct DataTrackSendTests {
    private static func frames(_ count: Int) -> AsyncStream<DataTrackFrame> {
        AsyncStream { continuation in
            for index in 0 ..< count {
                continuation.yield(DataTrackFrame(payload: Data([UInt8(index)])))
            }
            continuation.finish()
        }
    }

    /// Only the rejected frame is skipped; the rest of the sequence still goes out.
    @Test
    func dropSkipsRejectedFrames() async throws {
        let sink = RecordingSink { $0.payload == Data([2]) }
        try await sink.sendFrames(from: Self.frames(5), onQueueFull: .drop)

        #expect(sink.offered.copy().count == 5)
        #expect(sink.accepted.copy().map(\.payload) == [Data([0]), Data([1]), Data([3]), Data([4])])
    }

    /// `.throw` stops at the rejected frame and hands it back.
    @Test
    func throwStopsAtRejectedFrame() async throws {
        let sink = RecordingSink { $0.payload == Data([2]) }

        let error = await #expect(throws: DataTrackPushFrameError.self) {
            try await sink.sendFrames(from: Self.frames(5), onQueueFull: .throw)
        }
        guard case let .queueFull(_, frame) = try #require(error) else {
            Issue.record("Expected queueFull, got \(String(describing: error))")
            return
        }
        #expect(frame.payload == Data([2]), "The rejected frame should be handed back")
        #expect(sink.accepted.copy().map(\.payload) == [Data([0]), Data([1])])
    }

    /// Unpublishing mid-send ends the send quietly under either policy — it isn't a failure.
    @Test(arguments: [LocalDataTrack.FrameDropPolicy.drop, .throw])
    func unpublishingEndsSendQuietly(_ policy: LocalDataTrack.FrameDropPolicy) async throws {
        let sink = RecordingSink(unpublishAfter: 1)
        try await sink.sendFrames(from: Self.frames(5), onQueueFull: policy)
        #expect(sink.accepted.copy().count == 1)
    }

    /// An already-unpublished track sends nothing rather than throwing.
    @Test
    func unpublishedTrackSendsNothing() async throws {
        let sink = RecordingSink(isPublished: false)
        try await sink.sendFrames(from: Self.frames(3), onQueueFull: .throw)
        #expect(sink.offered.copy().isEmpty)
    }
}
