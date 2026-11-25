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

/// Bounded reads. `DataTrackStream` only ends when the track is unpublished, so a bare `next()`
/// waits forever if a frame is lost — on an unreliable channel that turns a failed assertion into
/// a hung job.
///
/// ## Why a bounded read may only ever happen once per stream
/// Abandoning a `next()` is not free. UniFFI's generated async has no cancellation path at all
/// (`uniffiRustCallAsync` is a bare poll loop — no `withTaskCancellationHandler`, no
/// `rust_future_cancel`), and the Rust wrapper holds a mutex across the await:
///
/// ```rust
/// pub struct DataTrackStream(Mutex<livekit_datatrack::api::DataTrackStream>);
/// pub async fn next(&self) -> Option<DataTrackFrame> {
///     self.0.lock().await.next().await.map(Into::into)   // TODO: avoid mutex?
/// }
/// ```
///
/// So a read that times out keeps that mutex until a frame happens to arrive, and every later
/// `next()` blocks behind it: **one timed-out read wedges the stream for good.** That is what made
/// the data-track tests look like a delivery failure — after the first timeout nothing more could
/// ever be read from that track, whatever was pushed.
///
/// `for await frame in stream` avoids *that* failure, because it never abandons a read, but it does
/// not escape the missing cancellation: the loop parks in the same `next()`, and cancelling its
/// task has no effect until a frame arrives or the track is unpublished. So the consumer below
/// outlives its `cancellable()` and is reaped at room teardown, when the stream ends — and a test
/// that awaits such a loop for a frame that never comes still hangs rather than failing.
extension DataTrackStream {
    /// The single bounded read a stream can safely be given, for tests that want one frame and do
    /// not want the reader draining the subscription's buffer.
    ///
    /// - Warning: At most one of these per stream, ever. To read repeatedly, use ``reader()``.
    func firstFrame(within timeout: TimeInterval = 15) async -> DataTrackFrame? {
        let frame = AsyncCompleter<DataTrackFrame?>(label: "data track frame", defaultTimeout: timeout)
        Task { await frame.resume(returning: self.next()) }
        return try? await frame.wait()
    }

    /// A reader that owns this stream's one and only `next()` caller.
    func reader() -> DataTrackReader { DataTrackReader(self) }
}

/// Owns the single task that ever calls `next()` on a stream, and buffers what it reads so tests
/// can take frames with a deadline without ever abandoning a read. See ``DataTrackStream``.
///
/// - Note: It drains the subscription continuously, so it cannot be used to observe the
///   subscription buffer's own drop-oldest behaviour.
/// - Note: Its consumer cannot be cancelled while parked in `next()`, so it ends when the stream
///   does — at room teardown — rather than when this is released.
final class DataTrackReader: Sendable {
    private struct State {
        var frames: [DataTrackFrame] = []
        var cursor: Int = 0
    }

    private let _state = StateSync(State())
    private let consumer: AnyTaskCancellable

    init(_ stream: DataTrackStream) {
        let state = _state
        consumer = Task {
            for await frame in stream {
                state.mutate { $0.frames.append(frame) }
            }
        }.cancellable()
    }

    /// The next frame this reader has not handed out yet, or `nil` if none arrives in time.
    func next(within timeout: TimeInterval = 15) async -> DataTrackFrame? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let frame = _state.mutate({ state -> DataTrackFrame? in
                guard state.cursor < state.frames.count else { return nil }
                defer { state.cursor += 1 }
                return state.frames[state.cursor]
            }) {
                return frame
            }
            guard Date() < deadline else { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Up to `count` frames matching `predicate`, or fewer if the deadline passes first.
    func collect(_ count: Int,
                 within timeout: TimeInterval = 15,
                 where predicate: @escaping @Sendable (DataTrackFrame) -> Bool = { _ in true }) async -> [DataTrackFrame]
    {
        var frames: [DataTrackFrame] = []
        let deadline = Date().addingTimeInterval(timeout)
        while frames.count < count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let frame = await next(within: remaining) else { break }
            if predicate(frame) { frames.append(frame) }
        }
        return frames
    }
}
