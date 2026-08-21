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

private final class FakeSendChannel: DataTrackSendChannel {
    var bufferedAmount: UInt64 = 0
    var isOpen = true
    var acceptsSends = true
    private(set) var sent: [Data] = []

    func send(packet: Data) -> Bool {
        guard acceptsSends else { return false }
        sent.append(packet)
        bufferedAmount += UInt64(packet.count)
        return true
    }

    /// Simulates the transport flushing its buffer (the trigger for a buffered-amount callback).
    func drain() { bufferedAmount = 0 }
}

/// Pins the outbound drain's semantics, which are deliberately aligned (and deliberately not)
/// with the other SDKs:
///
/// - **rust-sdks** (`DataChannelSender`): the same design — drop-oldest with a capacity-one frame
///   queue, whole-frame atomicity, packets metered on buffered-amount events with an 8 KiB
///   low-water mark. These tests mirror its invariants.
/// - **client-sdk-js** (`LossyDataChannel` with `bufferFullBehavior: 'wait'`): shares the
///   whole-frame atomicity and watermark pacing, but blocks the producer under load instead of
///   dropping — its engine awaits sends, so overload backpressures the frame producer. Swift's
///   producer is a fire-and-forget FFI callback with no backpressure channel, so freshest-wins
///   eviction is used instead (as in rust-sdks).
@Suite(.tags(.dataTrack))
struct DataTrackFrameSenderTests {
    private let channel = FakeSendChannel()
    private let sender = DataTrackFrameSender()

    init() {
        sender.attach(channel)
    }

    /// One packet per frame, tagged for identification.
    private func frame(_ tag: UInt8, packets: Int = 1, packetSize: Int = 100) -> [Data] {
        (0 ..< packets).map { _ in Data(repeating: tag, count: packetSize) }
    }

    @Test
    func sendsImmediatelyWithHeadroom() {
        sender.sendOrQueue(frame(1, packets: 3))
        #expect(channel.sent.count == 3)
    }

    /// The whole frame goes out even when it is far larger than the buffer headroom: packets are
    /// metered per drain instead of dumped, so there is no sender-imposed max frame size (all
    /// three SDKs share this property — JS by blocking the producer, Rust/Swift by metering).
    @Test
    func largeFrameStreamsWithinHeadroom() {
        let packetSize = 64000
        sender.sendOrQueue(frame(1, packets: 50, packetSize: packetSize))
        var pumps = 0
        while channel.sent.count < 50, pumps < 100 {
            // Each drain admits exactly one over-watermark packet, so the buffer never holds more
            // than one packet beyond the low-water mark.
            #expect(channel.bufferedAmount <= DataTrackFrameSender.lowWaterMark + UInt64(packetSize))
            channel.drain()
            sender.pump()
            pumps += 1
        }
        #expect(channel.sent.count == 50)
    }

    /// A newer frame evicts the queued (not yet started) one — freshest wins. This is the point
    /// of deliberate divergence from JS, which blocks the producer here instead of evicting;
    /// matches rust-sdks.
    @Test
    func dropsOldestQueuedFrame() {
        channel.bufferedAmount = DataTrackFrameSender.lowWaterMark + 1
        sender.sendOrQueue(frame(1))
        sender.sendOrQueue(frame(2))
        #expect(channel.sent.isEmpty)

        channel.drain()
        sender.pump()
        #expect(channel.sent.map(\.first) == [2])
    }

    /// An in-flight frame is never abandoned mid-send: its remaining packets go out before a
    /// newer frame, and packets of two frames never interleave. (The invariant all three SDKs
    /// agree on — "partial frames are never left on the wire".)
    @Test
    func inFlightFrameCompletesBeforeNewerFrame() {
        // Packet size above the watermark: each pump round admits one packet.
        sender.sendOrQueue(frame(1, packets: 3, packetSize: 64000))
        #expect(channel.sent.count == 1)

        sender.sendOrQueue(frame(2, packets: 2, packetSize: 64000))
        while channel.sent.count < 5 {
            channel.drain()
            sender.pump()
        }
        #expect(channel.sent.map(\.first) == [1, 1, 1, 2, 2])
    }

    /// Attaching a channel drops frames queued for the previous one (the analog of JS's
    /// `invalidateWaiters` on handle replacement — stale frames belong to a dead transport).
    @Test
    func attachClearsQueuedFrames() {
        channel.bufferedAmount = DataTrackFrameSender.lowWaterMark + 1
        sender.sendOrQueue(frame(1))

        let newChannel = FakeSendChannel()
        sender.attach(newChannel)
        sender.pump()
        #expect(newChannel.sent.isEmpty)

        sender.sendOrQueue(frame(2))
        #expect(newChannel.sent.map(\.first) == [2])
    }

    /// A rejected send drops the rest of the frame without wedging the pump.
    @Test
    func rejectedSendDropsFrameOnly() {
        channel.acceptsSends = false
        sender.sendOrQueue(frame(1, packets: 3))
        #expect(channel.sent.isEmpty)

        channel.acceptsSends = true
        sender.sendOrQueue(frame(2))
        #expect(channel.sent.map(\.first) == [2])
    }

    /// An empty packet batch must not evict a queued frame.
    @Test
    func emptyBatchIsIgnored() {
        channel.bufferedAmount = DataTrackFrameSender.lowWaterMark + 1
        sender.sendOrQueue(frame(1))
        sender.sendOrQueue([])

        channel.drain()
        sender.pump()
        #expect(channel.sent.map(\.first) == [1])
    }

    /// Nothing is sent while the channel is closed; opening drains the queue.
    @Test
    func queuedFrameDrainsOnceOpen() {
        channel.isOpen = false
        sender.sendOrQueue(frame(1))
        #expect(channel.sent.isEmpty)

        channel.isOpen = true
        sender.pump()
        #expect(channel.sent.map(\.first) == [1])
    }
}
