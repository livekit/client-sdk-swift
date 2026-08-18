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

internal import LiveKitUniFFI

/// A stream of frames received from a subscribed ``RemoteDataTrack``.
///
/// An `AsyncSequence`: Swift callers iterate with `for await frame in stream`; Objective-C
/// callers use ``read(onFrame:)``. The sequence ends when the track is unpublished or the
/// subscription is cancelled.
public final class DataTrackStream: NSObject, Sendable {
    private let stream: LiveKitUniFFI.DataTrackStream

    init(_ stream: LiveKitUniFFI.DataTrackStream) {
        self.stream = stream
        super.init()
    }

    /// Returns the next frame, or `nil` once the stream ends (the track is unpublished or the
    /// subscription is cancelled).
    public func next() async -> DataTrackFrame? {
        guard let frame = await stream.next() else { return nil }
        return DataTrackFrame(frame)
    }

    /// Delivers frames to `onFrame` until the stream ends.
    ///
    /// Objective-C entry point; Swift callers should prefer `for await frame in stream`.
    @objc public func read(onFrame: @escaping @Sendable (DataTrackFrame) -> Void) async {
        while let frame = await next() {
            onFrame(frame)
        }
    }
}

// MARK: - AsyncSequence

extension DataTrackStream: AsyncSequence {
    public typealias Element = DataTrackFrame

    /// Iterates the frames received on a ``DataTrackStream``.
    public struct Iterator: AsyncIteratorProtocol {
        let stream: DataTrackStream

        /// Returns the next frame, or `nil` once the stream ends.
        public mutating func next() async -> DataTrackFrame? {
            await stream.next()
        }
    }

    /// Creates an iterator over the frames received on this stream.
    public func makeAsyncIterator() -> Iterator {
        Iterator(stream: self)
    }
}
