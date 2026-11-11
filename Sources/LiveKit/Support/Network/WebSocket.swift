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

/// The peer's close frame, carried as the `internalError` of the thrown ``LiveKitError``: the stream fails with it, so
/// the signal client reconnects at once, as the JS, Android, Flutter and Rust SDKs do on a server close.
struct WebSocketClosedByPeer: Error, Sendable {
    /// The close code the peer sent; 1005 when it sent none.
    let code: UInt16
}

/// The signalling WebSocket: RFC 6455 frames over a Network.framework TCP (and TLS) connection.
///
/// One TCP read at a time feeds the frame parser, preserving buffered messages before a peer close.
/// Cancelling the connection releases its handlers and ends every pending read.
actor WebSocket: Loggable, AsyncSequence {
    typealias Element = URLSessionWebSocketTask.Message
    typealias EventHandler = @Sendable (Event) -> Void

    let connection: NWConnection
    enum TeardownCause: Sendable, Equatable {
        case closeFrame
        case closeDeadline
        case failure
    }

    enum Event: Sendable {
        /// A read waits for a frame.
        case receiveRegistered
        case closeStarted
        case teardown(TeardownCause)
        case closeDeadline
        /// The socket stopped reading with this many frames unread; TCP holds what follows until they are read.
        case readAheadFull(unread: Int)
    }

    private let core: Core
    /// Network.framework callbacks, including preferred-identity keychain reads, use this shared queue outside the cooperative pool.
    static var queue: DispatchQueue { .global(qos: .default) }
    /// URLSessionWebSocketTask's limit on a received message.
    static let maximumMessageSize = 1 << 20
    /// How many frames may wait unread before the socket stops reading. Nothing is dropped past it: TCP pushes back.
    static let readAhead = 16
    /// The most one TCP read takes.
    static let readSize = 1 << 18
    static let closeWait: TimeInterval = 0.25

    init(url: URL, headers: [(name: String, value: String)], timeoutInterval: TimeInterval,
         closeWait: TimeInterval = WebSocket.closeWait, onEvent: EventHandler? = nil) async throws
    {
        guard !Task.isCancelled else { throw LiveKitError(.cancelled) }
        #if targetEnvironment(simulator)
        if #available(iOS 26.0, *) {
            // iOS 26 Simulator TLS crash workaround (#738): https://developer.apple.com/forums/thread/787365?answerId=842938022
            nw_tls_create_options()
        }
        #endif

        var requestURL = url
        var requestHeaders = headers
        var redirects = 0
        var basicCredentials: [(url: URL, basic: (realm: String, value: String))] = []
        while true {
            do {
                let opened = try await Self.open(url: requestURL, headers: requestHeaders, timeoutInterval: timeoutInterval,
                                                 triedRealms: Set(basicCredentials.filter { Self.isInBasicProtectionSpace(requestURL, challengedURL: $0.url) }.map(\.basic.realm)),
                                                 closing: (closeWait, onEvent))
                connection = opened.connection
                core = opened.core
                core.start(after: opened.rest)
                return
            } catch let error as LiveKitError {
                guard let response = error.internalError as? WebSocketUpgradeFailure else { throw error }
                if let target = try Self.redirectedURL(response, from: requestURL) {
                    guard redirects < 20 else { throw LiveKitError(.network, internalError: URLError(.httpTooManyRedirects)) }
                    redirects += 1
                    requestHeaders.removeAll { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame }
                    if let credential = basicCredentials.last(where: { Self.isInBasicProtectionSpace(target, challengedURL: $0.url) }) {
                        requestHeaders.append(("Authorization", credential.basic.value))
                    }
                    requestURL = target
                } else if basicCredentials.count < 20, let basic = response.basicAuthorization {
                    basicCredentials.append((requestURL, basic))
                    requestHeaders.removeAll { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame }
                    requestHeaders.append(("Authorization", basic.value))
                } else {
                    throw LiveKitError(.network, internalError: WebSocketUpgradeFailure(statusCode: response.statusCode))
                }
            }
        }
    }

    private static func open(url: URL, headers: [(name: String, value: String)], timeoutInterval: TimeInterval,
                             triedRealms: Set<String>, closing: (wait: TimeInterval, onEvent: EventHandler?)) async throws -> Opened
    {
        guard !Task.isCancelled else { throw LiveKitError(.cancelled) }
        let key = Self.upgradeKey()
        // Rejects a header with a line break before any socket opens.
        _ = try Self.upgradeRequest(url: url, key: key, headers: headers)
        let connection = NWConnection(to: .url(url), using: Self.makeParameters(url: url, timeoutInterval: timeoutInterval))
        let core = Core(connection: connection, closeWait: closing.wait, onEvent: closing.onEvent)

        let opening = AsyncCompleter<UpgradeResponse>(label: "WebSocket.open", defaultTimeout: timeoutInterval)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                do {
                    let headers = Self.upgradeHeaders(url: url, headers: headers)
                    let request = try Self.upgradeRequest(url: url, key: key, headers: headers)
                    let compressionOffered = WebSocketCompression.isOffered(in: headers)
                    connection.send(content: request, completion: .contentProcessed { _ in })
                    Self.readUpgradeResponse(connection, url: url, key: key, options: (compressionOffered, triedRealms), into: opening)
                } catch {
                    opening.resume(with: .failure(error))
                }
            case let .failed(error), let .waiting(error):
                // `.waiting` too: a connection that cannot be made now fails, as URLSession's did
                // (waitsForConnectivity off); the signal client owns the retries.
                opening.resume(with: .failure(error))
            default:
                break
            }
        }
        connection.start(queue: Self.queue)
        let response: UpgradeResponse
        do {
            response = try await opening.wait()
            try core.configure(response.compression)
        } catch let error as NWError {
            core.finish()
            throw LiveKitError(.network, internalError: Self.bridged(error))
        } catch {
            core.finish()
            throw error is LiveKitError ? error : LiveKitError.from(error: error) ?? LiveKitError(.unknown)
        }
        return Opened(connection: connection, core: core, rest: response.rest)
    }

    deinit {
        core.close()
    }

    /// Sends a close frame with code 1000, as `URLSessionWebSocketTask.cancel(with: .normalClosure)` did, and cancels
    /// once the server answers or after 250 ms (the JS SDK's wait), whichever comes first. Does not block. Every read,
    /// a pending one too, ends at once with nil, and unread messages are dropped. Only the first call sends anything.
    nonisolated func close() {
        core.close()
    }

    /// Below iOS 16 and macOS 13 a cancelled connection keeps its state handler, and whatever that captures.
    fileprivate static func cancel(_ connection: NWConnection) {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    // MARK: - AsyncSequence

    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let core: Core

        func next() async throws -> URLSessionWebSocketTask.Message? {
            switch await core.read() {
            case let .message(message): message
            case let .failed(error): throw error
            case .closed: nil
            }
        }
    }

    nonisolated func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(core: core)
    }

    // MARK: - Send

    nonisolated func send(data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            do {
                guard try core.send(data, completion: { error in
                    if let error {
                        continuation.resume(throwing: LiveKitError(.network, internalError: WebSocket.bridged(error)))
                    } else {
                        continuation.resume()
                    }
                }) else { return continuation.resume(throwing: LiveKitError(.network, internalError: URLError(.cancelled))) }
            } catch {
                core.finish()
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Core

private struct Opened {
    let connection: NWConnection
    let core: Core
    let rest: Data
}

private struct Lifecycle {
    enum Phase { case open, closing, closed }
    var phase: Phase = .open
    var compressor: WebSocketCompression.Codec?
    var pongInFlight = false
    var nextPong: Data?
}

/// The connection, and what reads, writes and ends it: shared by the socket, its iterators and the callbacks.
private struct Core: Sendable {
    let connection: NWConnection
    let lifecycle = StateSync(Lifecycle())
    let inbox = StateSync(WebSocket.Inbox())
    let closeWait: TimeInterval
    let onEvent: WebSocket.EventHandler?

    func configure(_ compression: WebSocketCompression?) throws {
        guard let compression else { return }
        let inflater = try WebSocketCompression.Codec(compressing: false, windowBits: compression.serverWindowBits,
                                                      noContextTakeover: compression.serverNoContextTakeover)
        let deflater = try WebSocketCompression.Codec(compressing: true, windowBits: compression.clientWindowBits,
                                                      noContextTakeover: compression.clientNoContextTakeover)
        inbox.mutateWithoutObservation { $0.parser = WebSocketFrame.Parser(maximumMessageSize: WebSocket.maximumMessageSize, inflater: inflater) }
        lifecycle.mutate { $0.compressor = deflater }
    }

    /// Compresses and writes `data` while the socket is open, under the lock that our close frame is written under, so
    /// that frames keep the deflate context's order and none follows our close frame. Holding the lock is safe:
    /// `connection.send` only queues, and its completion runs later on the connection's queue. False once closing.
    func send(_ data: Data, completion: @escaping @Sendable (NWError?) -> Void) throws -> Bool {
        try lifecycle.mutate { state in
            guard state.phase == .open else { return false }
            let payload = try state.compressor?.process(data, final: true) ?? data
            connection.send(content: WebSocketFrame.client(opcode: WebSocketFrame.binary, payload, compressed: state.compressor != nil),
                            completion: .contentProcessed(completion))
            return true
        }
    }

    /// Our close: every read ends at once with nil, unread messages are dropped, our close frame goes out, and the
    /// connection is cancelled on the server's answer or at the deadline.
    func close() {
        let readers = inbox.mutateWithoutObservation { inbox in
            inbox.ended = true
            inbox.dropUnread()
            defer { inbox.readers.removeAll() }
            return inbox.readers
        }
        for reader in readers {
            reader.resume(returning: .closed)
        }
        // Past the read-ahead limit too: the server's answer comes after whatever it still sends.
        step { $0.parse() }
        guard startClosing(code: 1000, finishOnceWritten: false) else { return }
        onEvent?(.closeStarted)
    }

    /// Moves an open socket to closing and writes our close frame, under the lock that every frame is written under, so
    /// that no frame follows it. Holding the lock is safe, as for ``send(_:completion:)``: its completion takes the lock
    /// again later, on the connection's queue. Every way into closing passes here, so the connection always goes: once the frame is
    /// written if `finishOnceWritten`, on the server's answer otherwise, and at the latest 250 ms on (the JS SDK's wait),
    /// even when the frame waits behind a write that TCP holds up. False when the socket is not open.
    private func startClosing(code: UInt16, finishOnceWritten: Bool) -> Bool {
        guard lifecycle.mutate({
            guard $0.phase == .open else { return false }
            $0.phase = .closing
            connection.send(content: WebSocketFrame.clientClose(code), completion: .contentProcessed { _ in
                if finishOnceWritten { finish(cause: .closeFrame) }
            })
            return true
        }) else { return false }
        WebSocket.queue.asyncAfter(deadline: .now() + closeWait) {
            finish(cause: .closeDeadline)
            onEvent?(.closeDeadline)
        }
        return true
    }

    func finish(cause: WebSocket.TeardownCause = .failure) {
        guard lifecycle.mutate({
            guard $0.phase != .closed else { return false }
            $0.phase = .closed
            return true
        }) else { return }
        WebSocket.cancel(connection)
        onEvent?(.teardown(cause))
    }

    func read() async -> WebSocket.Frame {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WebSocket.Frame, Never>) in
                var frame: WebSocket.Frame?
                step { inbox in
                    frame = inbox.take()
                    guard frame != nil else {
                        inbox.readers.append(continuation)
                        return WebSocket.Reply()
                    }
                    return inbox.parse()
                }
                if let frame { continuation.resume(returning: frame) } else { onEvent?(.receiveRegistered) }
            }
        } onCancel: {
            // As the URLSession task's `cancel(with: .normalClosure)`: `SignalClient.cleanUp` cancels the
            // read before it calls `close()`.
            close()
        }
    }

    /// Takes the frames that came in the same segment as the upgrade response, and from then on watches the connection
    /// only for a failure: the upgrade's state handler, and what it holds, goes. The frames may already have closed the
    /// socket; then `finish()` cleared the handlers, and a new one would keep the connection alive through itself.
    func start(after rest: Data) {
        received(rest, isComplete: false, error: nil)
        lifecycle.mutate { state in
            guard state.phase != .closed else { return }
            connection.stateUpdateHandler = { [self] state in
                if case let .failed(error) = state { failed(error) }
            }
        }
        if case let .failed(error) = connection.state { failed(error) }
    }

    /// The connection failed with no read in flight to say so: reads throw `error` after the messages already read.
    private func failed(_ error: NWError) {
        step { inbox in
            inbox.receiving ? WebSocket.Reply() : inbox.ingest(nil, isComplete: false, error: error)
        }
    }

    /// Takes what a TCP read brought: parses it, hands frames to the reads that wait, answers pings and the server's
    /// close frame, and reads on unless ``WebSocket/readAhead`` frames wait unread.
    func received(_ content: Data?, isComplete: Bool, error: NWError?) {
        step { inbox in
            inbox.receiving = false
            return inbox.ingest(content, isComplete: isComplete, error: error)
        }
    }

    /// Runs `change` on the inbox, then does what it asks: answers, hands frames to the reads that wait, and reads on.
    private func step(_ change: (inout WebSocket.Inbox) -> WebSocket.Reply) {
        let (reply, handed, readOn, paused) = inbox.mutateWithoutObservation { inbox in
            var reply = change(&inbox)
            let handed = inbox.handOut(into: &reply)
            let readOn = inbox.startReceive()
            let paused = !readOn && !inbox.receiving && !inbox.done && inbox.unread >= WebSocket.readAhead
            return (reply, handed, readOn, paused ? inbox.unread : nil)
        }
        if let payload = reply.pong { pong(payload) }
        if let code = reply.closeCode { answer(code) } else if reply.failed { finish() }
        for (reader, frame) in handed {
            reader.resume(returning: frame)
        }
        if readOn { receiveNext() } else if let paused { onEvent?(.readAheadFull(unread: paused)) }
    }

    /// Answers the latest ping with one pong in flight at most: pings that arrive meanwhile leave only the latest to answer.
    /// Written under the lock that our close frame is written under, so that no pong follows it; the completion takes
    /// that lock again later, on the connection's queue.
    private func pong(_ payload: Data? = nil, written: Bool = false) {
        lifecycle.mutate { state in
            if written { state.pongInFlight = false }
            if let payload { state.nextPong = payload }
            guard state.phase == .open, !state.pongInFlight, let next = state.nextPong else { return }
            state.nextPong = nil
            state.pongInFlight = true
            connection.send(content: WebSocketFrame.client(opcode: WebSocketFrame.pong, next),
                            completion: .contentProcessed { _ in pong(written: true) })
        }
    }

    /// The stream ended with a close frame from the server, or broke the protocol. The server's close frame ends the
    /// handshake when it answers ours; otherwise our close frame goes out with `code`, and the connection with it.
    private func answer(_ code: UInt16) {
        guard startClosing(code: code, finishOnceWritten: true) else { return finish(cause: .closeFrame) }
    }

    /// One TCP read at a time, as `Inbox.startReceive()` grants it.
    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: WebSocket.readSize) { content, _, isComplete, error in
            received(content, isComplete: isComplete, error: error)
        }
    }
}
