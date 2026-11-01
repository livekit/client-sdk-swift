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
import Network

extension WebSocket {
    /// What a read hands out.
    enum Frame: Sendable {
        case message(URLSessionWebSocketTask.Message)
        /// The stream is over: thrown, and the sequence ends.
        case failed(LiveKitError)
        /// Our own close: the sequence ends with nil.
        case closed
    }

    /// What the connection does after a read, besides handing out frames.
    struct Reply {
        var pongs: [Data] = []
        /// The code of our close frame: the server's own, to answer its close frame, or ours for a stream that broke the
        /// protocol. The connection goes once it is written.
        var closeCode: UInt16?
        /// The connection broke: it goes without a close frame.
        var failed = false
    }

    /// The parsed frames that no iterator has read yet, and the reads that wait for one. At most one TCP read is in flight,
    /// and none starts while ``WebSocket/readAhead`` frames wait: unread frames stay below that plus what one read of up to
    /// 64 KB holds.
    struct Inbox {
        var parser = WebSocketFrame.Parser(maximumMessageSize: WebSocket.maximumMessageSize)
        private var frames: [Frame] = []
        private var taken = 0
        /// Reads that wait for a frame, first come, first served.
        var readers: [CheckedContinuation<Frame, Never>] = []
        var receiving = false
        /// A close frame, a failure or the end of the stream arrived: nothing more is read.
        private(set) var done = false
        /// Our own close, or the frame that ended the stream, was read: every later read ends the sequence.
        var ended = false

        var unread: Int { frames.count - taken }

        /// The frames held, read or not: at most twice the unread ones, plus one.
        var retainedFrames: Int { frames.count }

        /// The message bytes that the held frames carry.
        var retainedBytes: Int {
            frames.reduce(0) { total, frame in
                guard case let .message(message) = frame else { return total }
                return switch message {
                case let .data(data): total + data.count
                case let .string(text): total + text.utf8.count
                @unknown default: total
                }
            }
        }

        mutating func take() -> Frame? {
            if ended { return .closed }
            guard taken < frames.count else { return nil }
            let frame = frames[taken]
            taken += 1
            // Drops the read ones once they are as many as the unread: the order stays, and the cost spreads over reads.
            if taken * 2 >= frames.count {
                frames.removeFirst(taken)
                taken = 0
            }
            if case .failed = frame { ended = true }
            return frame
        }

        mutating func handOut() -> [(reader: CheckedContinuation<Frame, Never>, frame: Frame)] {
            var handed: [(reader: CheckedContinuation<Frame, Never>, frame: Frame)] = []
            while !readers.isEmpty, let frame = take() {
                handed.append((readers.removeFirst(), frame))
            }
            return handed
        }

        mutating func dropUnread() {
            frames.removeAll(keepingCapacity: true)
            taken = 0
        }

        /// Whether a TCP read may start now; if so, it counts as started.
        mutating func startReceive() -> Bool {
            guard !receiving, !done, unread < WebSocket.readAhead else { return false }
            receiving = true
            return true
        }

        /// Parses what a read brought, its content before its error or end of stream.
        mutating func ingest(_ content: Data?, isComplete: Bool, error: NWError?) -> Reply {
            var reply = Reply()
            guard !done else { return reply }
            if let content { parser.append(content) }
            while !done, let item = parser.next() {
                apply(item, to: &reply)
            }
            guard !done, error != nil || isComplete else { return reply }
            // The stream ends with no close frame, between frames or inside one: the sequence fails.
            reply.failed = true
            end(LiveKitError(.network, internalError: error.map(WebSocket.bridged) ?? URLError(.networkConnectionLost)))
            return reply
        }

        private mutating func apply(_ item: WebSocketFrame.Item, to reply: inout Reply) {
            switch item {
            case let .message(message):
                if !ended { frames.append(.message(message)) }
            case let .ping(payload):
                reply.pongs.append(payload)
            case .pong:
                break
            case let .close(code):
                // An error, not the end of the stream, which only our own close is.
                reply.closeCode = code
                end(LiveKitError(.network, message: "Closed by the peer (\(code))", internalError: WebSocketClosedByPeer(code: code)))
            case let .failure(error, closeCode):
                reply.closeCode = closeCode
                end(error)
            }
        }

        /// Ends the stream with `error`, which a read throws after every frame before it.
        private mutating func end(_ error: LiveKitError) {
            if !ended { frames.append(.failed(error)) }
            done = true
        }
    }
}
