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

/// Local mirror of how many bytes a data channel has yet to drain, and the low-water gate the drain
/// consults before each write.
///
/// ## Why the amount is mirrored rather than read back
/// `LKRTCDataChannelDelegate.dataChannel(_:didChangeBufferedAmount:)` reports the number of bytes
/// *drained* since the last report, not the current level: libwebrtc's
/// `SctpDataChannel::MaybeSendOnBufferedAmountChanged` sends a diff, and only once ≥100 KiB has
/// drained or the buffer empties. `LKRTCDataChannel.bufferedAmount` would give the level directly,
/// but it is a `PROXY_SECONDARY_CONSTMETHOD0` getter, so reading it blocks on WebRTC's network
/// thread.
///
/// Lives in ``DataChannelDrain``'s event-loop state and is touched only by its single consumer, so
/// it needs no synchronization of its own.
struct BufferedAmountMeter {
    /// Feed the channel only while the mirror sits at or below this many bytes.
    private(set) var lowWaterMark: UInt64

    private(set) var pending: UInt64 = 0

    var hasHeadroom: Bool { pending <= lowWaterMark }

    /// Bytes about to be handed to the channel.
    ///
    /// Counted *before* the hand-off so the mirror is never behind what the transport holds:
    /// counting after leaves a window where a drain report for those bytes arrives first, subtracts
    /// them from a mirror that has not seen them, and then has them added back — leaving the gate
    /// closed with nothing left to drain.
    mutating func willSend(_ byteCount: Int) {
        pending += UInt64(byteCount)
    }

    /// Bytes the channel reported draining since its last report, or bytes returned because the
    /// channel rejected them.
    ///
    /// - Returns: `false` when the report exceeds the mirror, which means the two have drifted —
    ///   the channel was torn down with bytes outstanding, or `sendData` reported success for bytes
    ///   libwebrtc then discarded. Self-heals to zero rather than trapping; the mirror is only a
    ///   gate. A report against an *empty* mirror is expected right after ``reset()`` and is not
    ///   reported as drift.
    @discardableResult
    mutating func didDrain(_ byteCount: UInt64) -> Bool {
        let drifted = pending > 0 && pending < byteCount
        pending = pending < byteCount ? 0 : pending - byteCount
        return !drifted
    }

    /// The channel is gone or is being swapped: nothing previously queued is outstanding on its
    /// replacement, so the mirror starts over. Without this a mirror left above the mark would gate
    /// the replacement channel with no drain report coming to clear it.
    mutating func reset() {
        pending = 0
    }

    /// Retunes the gate. The mirror is unaffected — only how much of it counts as too much.
    mutating func setLowWaterMark(_ mark: UInt64) {
        lowWaterMark = mark
    }
}
