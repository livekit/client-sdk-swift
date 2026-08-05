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
public struct DataStreamOptions: Sendable, Equatable, Hashable {
    /// Maximum size, in bytes, of an incoming data-stream payload the receiver will accept.
    ///
    /// A stream whose reassembled payload would exceed this cap fails the read rather than buffering
    /// unbounded data. `nil` (the default) uses the SDK's built-in cap of 5gb.
    public let maxPayloadSize: Int?

    public init(maxPayloadSize: Int? = nil) {
        self.maxPayloadSize = maxPayloadSize
    }
}
