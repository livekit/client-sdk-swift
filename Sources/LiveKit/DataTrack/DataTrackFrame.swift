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

/// A single unit of application data sent or received over a data track.
public final class DataTrackFrame: NSObject, Sendable {
    /// The application payload carried by this frame.
    @objc public let payload: Data

    /// Optional sender-provided timestamp, in milliseconds since the Unix epoch.
    ///
    /// Carried end-to-end unmodified; useful for measuring latency. Objective-C callers can use
    /// ``userTimestampMs``.
    public let userTimestamp: UInt64?

    /// Objective-C accessor for ``userTimestamp`` (`nil` when no timestamp is set).
    @objc public var userTimestampMs: NSNumber? {
        userTimestamp.map { NSNumber(value: $0) }
    }

    /// How long ago the frame was stamped, or `nil` if it carries no timestamp or the timestamp
    /// lies in the future.
    ///
    /// Assumes ``userTimestamp`` is a Unix timestamp in milliseconds, as set by ``now(payload:)``.
    /// Objective-C callers can use ``secondsSinceTimestamp``.
    public var durationSinceTimestamp: TimeInterval? {
        guard let userTimestamp else { return nil }
        let elapsed = Date().timeIntervalSince1970 - TimeInterval(userTimestamp) / 1000
        return elapsed >= 0 ? elapsed : nil
    }

    /// Objective-C accessor for ``durationSinceTimestamp``.
    @objc(durationSinceTimestamp) public var secondsSinceTimestamp: NSNumber? {
        durationSinceTimestamp.map { NSNumber(value: $0) }
    }

    /// Creates a frame with an optional sender timestamp.
    public init(payload: Data, userTimestamp: UInt64? = nil) {
        self.payload = payload
        self.userTimestamp = userTimestamp
        super.init()
    }

    /// Creates a frame with no timestamp.
    @objc public convenience init(payload: Data) {
        self.init(payload: payload, userTimestamp: nil)
    }

    /// Creates a frame stamped with the given timestamp, in milliseconds since the Unix epoch.
    @objc public convenience init(payload: Data, userTimestampMs: UInt64) {
        self.init(payload: payload, userTimestamp: userTimestampMs)
    }

    /// Creates a frame stamped with the current time, in milliseconds since the Unix epoch.
    @objc public static func now(payload: Data) -> DataTrackFrame {
        DataTrackFrame(payload: payload, userTimestamp: UInt64(Date().timeIntervalSince1970 * 1000))
    }

    init(_ frame: LiveKitUniFFI.DataTrackFrame) {
        payload = frame.payload
        userTimestamp = frame.userTimestamp
        super.init()
    }

    var ffi: LiveKitUniFFI.DataTrackFrame {
        LiveKitUniFFI.DataTrackFrame(payload: payload, userTimestamp: userTimestamp)
    }

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return payload == other.payload && userTimestamp == other.userTimestamp
    }

    override public var hash: Int {
        var hasher = Hasher()
        payload.hash(into: &hasher)
        userTimestamp.hash(into: &hasher)
        return hasher.finalize()
    }
}
