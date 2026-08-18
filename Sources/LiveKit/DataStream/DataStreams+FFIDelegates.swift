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

// The objects the Rust core calls into. Split from `DataStreams` itself so the coordinator file
// stays about coordination; each type here is a thin adapter that forwards across the boundary.
extension DataStreams {
    // MARK: - Incoming delegate

    /// Receives the incoming manager's stream-open callbacks and forwards them to the coordinator.
    /// A separate object because the FFI manager retains its delegate strongly; holding the
    /// coordinator weakly keeps this the weak link so teardown doesn't leak.
    final class IncomingDelegate: LiveKitUniFFI.IncomingDataStreamManagerDelegate, @unchecked Sendable {
        weak var coordinator: DataStreams?

        func onByteStreamOpened(reader: LiveKitUniFFI.ByteStreamReader, identity: String) {
            coordinator?.handleByteStreamOpened(reader, identity: identity)
        }

        func onTextStreamOpened(reader: LiveKitUniFFI.TextStreamReader, identity: String) {
            coordinator?.handleTextStreamOpened(reader, identity: identity)
        }

        func onStreamClosed(streamId: String, identity: String) {
            coordinator?.handleStreamClosed(streamID: streamId, identity: identity)
        }
    }

    // MARK: - Outgoing delegate

    /// Receives the outgoing manager's encoded `DataPacket`s and sends them over the reliable data
    /// channel via `Room.send(dataPacket:)` — preserving E2EE, reliable sequencing, and identity
    /// stamping. The room is held weakly to avoid retaining it through the FFI manager.
    ///
    /// Order is structural, not incidental. A stream's packets must reach the SFU in emission order:
    /// the receiver drops a chunk that arrives before its header and fails the stream outright on a
    /// non-consecutive chunk index. The FFI calls `onPacketsAvailable` synchronously and strictly
    /// sequentially, so this delegate only has to *preserve* that order — hence a single drain task
    /// over an `AsyncStream`, rather than a task per callback racing to a serial executor.
    /// Fully `Sendable`, not `@unchecked`: both stored properties are immutable and `Sendable`, so
    /// there is no invariant here for a reviewer to have to take on trust.
    final class OutgoingDelegate: LiveKitUniFFI.OutgoingDataStreamManagerDelegate {
        private let continuation: AsyncStream<[Data]>.Continuation
        // Unstructured on purpose: the pump's lifetime is the delegate's, not any caller's. Wrapped so
        // it is cancelled on deinit rather than outliving the object (SwiftLint enforces this shape).
        private let pump: AnyTaskCancellable

        init(room: Room) {
            let (stream, continuation) = AsyncStream.makeStream(of: [Data].self)
            self.continuation = continuation
            pump = Task.detached { [weak room] in
                for await packets in stream {
                    guard let room else { return }
                    for data in packets {
                        guard let packet = try? Livekit_DataPacket(serializedBytes: data) else {
                            room.log("Failed to decode outgoing data stream packet", .warning)
                            continue
                        }
                        try? await room.send(dataPacket: packet)
                    }
                }
            }.cancellable()
        }

        deinit {
            continuation.finish()
        }

        func onPacketsAvailable(packets: [Data]) throws {
            // The FFI asks us to return only once the packets reached the transport, so that the
            // originating `write`/`send_*` bounds how fast a producer can enqueue. We can't honor
            // that here: this callback is synchronous and every send path on `Room` is `async`, so
            // waiting would mean blocking the calling thread on an async result — a synchronisation
            // primitive this SDK doesn't allow, and one that would stall a Rust runtime thread.
            //
            // Handing off to the ordered pump keeps emission order and surfaces decode failures, but
            // acknowledges before the wire write, so back-pressure and transport errors are still
            // not propagated. Closing that gap needs `on_packets_available` to be an `async fn` on
            // the Rust trait, which uniffi supports for foreign traits; raised upstream.
            continuation.yield(packets)
        }
    }

    // MARK: - Remote participant registry

    /// Read access to the room's remote participants, used by the outgoing manager to resolve
    /// broadcast recipients and decide compression eligibility. Client protocol/capabilities aren't
    /// currently exposed on `RemoteParticipant`, so they default to none — compression stays off
    /// until they're wired, which is a safe default (a non-compressed send always works).
    final class Registry: LiveKitUniFFI.RemoteParticipantRegistryDelegate, @unchecked Sendable {
        private weak var room: Room?

        init(room: Room) {
            self.room = room
        }

        private func participant(for identity: String) -> RemoteParticipant? {
            room?.remoteParticipants.first { $0.key.stringValue == identity }?.value
        }

        func remoteClientProtocol(identity: String) -> Int32 {
            Int32(participant(for: identity)?.clientProtocol.rawValue ?? 0)
        }

        func remoteCapabilities(identity: String) -> [LiveKitUniFFI.ClientCapability] {
            participant(for: identity)?.capabilities.map(\.ffiValue) ?? []
        }

        func remoteIdentities() -> [String] {
            guard let room else { return [] }
            return room.remoteParticipants.keys.map(\.stringValue)
        }
    }
}

private extension ClientCapability {
    /// Bridges to the FFI enum. Kept here so `ClientCapability` itself stays free of any
    /// `LiveKitUniFFI` import, matching how the rest of the public API is layered.
    var ffiValue: LiveKitUniFFI.ClientCapability {
        switch self {
        case .packetTrailer: .packetTrailer
        case .compressionDeflateRaw: .compressionDeflateRaw
        }
    }
}
