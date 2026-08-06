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

internal import LiveKitWebRTC

/// The slice of the RTC data channel the outbound drain drives — a seam so the drain logic is
/// unit-testable (`LKRTCDataChannel` can't be constructed without a live peer connection).
protocol DataTrackSendChannel: AnyObject {
    var bufferedAmount: UInt64 { get }
    var isOpen: Bool { get }
    func send(packet: Data) -> Bool
}

extension LKRTCDataChannel: DataTrackSendChannel {
    var isOpen: Bool { readyState == .open }
    func send(packet: Data) -> Bool {
        // Constructed directly: the drain already runs on `DispatchQueue.liveKitWebRTC`, so
        // `RTC.createDataBuffer`'s sync hop onto that queue would trap. The buffer is a plain
        // container — the helper's queue exists to serialize factory access, which being on the
        // queue already satisfies.
        sendData(LKRTCDataBuffer(data: packet, isBinary: true))
    }
}

/// Drop-oldest outbound drain for data-track frames; mirrors `DataChannelSender` in rust-sdks.
///
/// Packets are metered into the channel on buffered-amount events instead of dumped, keeping the
/// SCTP buffer near ``lowWaterMark`` (so a frame of any size streams out safely) and bounding send
/// latency: at most one frame waits while another drains, and a newer frame evicts the waiting
/// one. Frames are handled whole — a partial frame is never left on the wire.
///
/// Not thread-safe: the owner confines all calls to one queue (`DispatchQueue.liveKitWebRTC` in
/// production; buffered-amount and state callbacks arrive from WebRTC's threads and hop over).
final class DataTrackFrameSender: Loggable {
    /// Resume sending when the channel buffer drains to this level; parity with
    /// `DATA_TRACK_BUFFERED_AMOUNT_LOW_THRESHOLD` in rust-sdks.
    static let lowWaterMark: UInt64 = 8 * 1024

    private var channel: DataTrackSendChannel?
    /// Freshest queued frame (capacity one — a newer frame evicts it).
    private var pendingFrame: [Data]?
    /// Packets of the frame currently draining, in FIFO order.
    private var inFlight: [Data] = []

    /// Attaches the channel this sender drains into, dropping frames queued for the previous one
    /// (they belong to a torn-down transport).
    func attach(_ channel: DataTrackSendChannel) {
        self.channel = channel
        pendingFrame = nil
        inFlight = []
    }

    /// Queues a frame's packets for sending, evicting a previously queued frame (drop-oldest).
    func sendOrQueue(_ packets: [Data]) {
        guard !packets.isEmpty else { return }
        if let evicted = pendingFrame {
            log("Evicted queued data track frame (\(evicted.count) packets) in favor of a newer one", .debug)
        }
        pendingFrame = packets
        pump()
    }

    /// Feeds packets to the channel while it has headroom, promoting the queued frame when the
    /// in-flight one is fully handed off.
    func pump() {
        guard let channel, channel.isOpen else { return }
        while channel.bufferedAmount <= Self.lowWaterMark {
            if inFlight.isEmpty {
                guard let next = pendingFrame else { return }
                pendingFrame = nil
                inFlight = next
            }
            guard let packet = inFlight.first else { return }
            guard channel.send(packet: packet) else {
                log("Data track channel rejected packet; dropping frame (\(inFlight.count) packets)", .debug)
                inFlight = []
                return
            }
            inFlight.removeFirst()
        }
    }
}
