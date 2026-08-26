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

/// One of the outbound data channels a room publishes on.
///
/// Used by ``RoomDelegate/room(_:didUpdateBufferStatus:of:)`` to say which channel's send buffer
/// changed. Each is an independent SCTP stream with its own buffer and its own behaviour when that
/// buffer fills.
@objc
public enum DataChannelKind: Int, Sendable {
    /// Carries data published with `reliable: false`. Drops the oldest queued payload under
    /// backpressure rather than delaying newer ones.
    case lossy

    /// Carries data published with `reliable: true`, plus data streams and RPC. Queues without
    /// bound and delivers in order, so a full buffer delays publishing rather than losing it.
    case reliable

    /// Carries published data-track frames. Drops the oldest queued frame under backpressure.
    case dataTrack
}
