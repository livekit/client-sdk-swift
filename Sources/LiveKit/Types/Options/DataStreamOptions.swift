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

/// Options controlling how the ``Room`` handles incoming data streams.
@objcMembers
public final class DataStreamOptions: NSObject, Sendable {
    /// Maximum size, in bytes, of an incoming data-stream payload the receiver will accept.
    ///
    /// A stream whose reassembled payload would exceed this cap fails the read rather than buffering
    /// unbounded data. `nil` (the default) uses the SDK's built-in cap of 5gb.
    ///
    /// - Note: A value of zero or less is treated as `nil`, falling back to the built-in cap.
    public let maxPayloadSize: Int?

    /// ``maxPayloadSize`` as an `NSNumber`, for Objective-C callers.
    ///
    /// `Int?` is not representable in Objective-C, so the optional is bridged rather than exposed
    /// directly; `nil` here means the same as `nil` there.
    public var maxPayloadSizeNumber: NSNumber? {
        maxPayloadSize.map { NSNumber(value: $0) }
    }

    /// Creates options with the given incoming payload cap.
    ///
    /// - Parameter maxPayloadSize: Cap in bytes, or `nil` for the SDK's built-in cap. Values of zero
    ///   or less are treated as `nil`.
    public init(maxPayloadSize: Int?) {
        self.maxPayloadSize = maxPayloadSize.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Creates options with the default incoming payload cap.
    override public init() {
        maxPayloadSize = nil
    }

    /// Objective-C-compatible initializer that accepts `NSNumber?` for ``maxPayloadSize``.
    public convenience init(maxPayloadSizeNumber: NSNumber?) {
        self.init(maxPayloadSize: maxPayloadSizeNumber?.intValue)
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return maxPayloadSize == other.maxPayloadSize
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(maxPayloadSize)
        return hasher.finalize()
    }
}
