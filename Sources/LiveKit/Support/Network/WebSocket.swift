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
import Security

/// The peer's close frame, carried as the `internalError` of the thrown ``LiveKitError``: the stream fails with it, so
/// the signal client reconnects at once, as the JS, Android, Flutter and Rust SDKs do on a server close.
struct WebSocketClosedByPeer: Error, Sendable {
    /// The close code the peer sent; 1005 when it sent none.
    let code: UInt16
}

/// The signalling WebSocket: RFC 6455 frames over a Network.framework TCP (and TLS) connection.
///
/// Not `URLSessionWebSocketTask`: Foundation keeps every `URLSession` that ran a WebSocket task, and the task,
/// alive after the task is cancelled and the session invalidated, whichever way it is closed (about 25 KB a
/// connection, measured on macOS 27 and the iOS 26.5 simulator). Every full or quick reconnect left one behind
/// for the life of the process. An `NWConnection` is freed once cancelled.
///
/// Not `NWProtocolWebSocket` either: it drops the messages it holds when a close frame arrives with no receive waiting
/// for them, and the server sends its leave request right before its close frame. Here one TCP read at a time feeds
/// one parser, as in SwiftNIO, Starscream and SocketRocket, so a close frame is read after every message before it.
actor WebSocket: Loggable, AsyncSequence {
    typealias Element = URLSessionWebSocketTask.Message
    typealias EventHandler = @Sendable (Event) -> Void

    let connection: NWConnection
    enum Event: Sendable {
        /// A read waits for a frame.
        case receiveRegistered
        case closeStarted
        case teardown
        case closeDeadline
        /// The socket stopped reading with this many frames unread; TCP holds what follows until they are read.
        case readAheadFull(unread: Int)
    }

    private let core: Core
    /// Network.framework delivers on a queue it is given; a shared one, not one of our own: every callback here only
    /// parses what arrived, or resumes an `AsyncCompleter` or a continuation.
    fileprivate static var queue: DispatchQueue { .global(qos: .default) }
    /// URLSessionWebSocketTask's limit on a received message.
    static let maximumMessageSize = 1 << 20
    /// How many frames may wait unread before the socket stops reading. Nothing is dropped past it: TCP pushes back.
    static let readAhead = 16

    static func makeParameters(secure: Bool, timeoutInterval: TimeInterval) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Swift.max(1, Int(timeoutInterval.rounded(.up)))
        // URLSession turned Nagle off; signal messages are small.
        tcp.noDelay = true
        let tls = secure ? NWProtocolTLS.Options() : nil
        if let tls {
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        }
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // As `.callSignaling` on the URLSession configuration this replaces.
        parameters.serviceClass = .signaling
        #if os(iOS) || os(visionOS)
        // https://developer.apple.com/documentation/foundation/urlsessionconfiguration/improving_network_reliability_using_multipath_tcp
        parameters.multipathServiceType = .handover
        #endif
        return parameters
    }

    init(url: URL, headers: [(name: String, value: String)], timeoutInterval: TimeInterval,
         onEvent: EventHandler? = nil) async throws
    {
        guard !Task.isCancelled else { throw LiveKitError(.cancelled) }
        #if targetEnvironment(simulator)
        if #available(iOS 26.0, *) {
            nw_tls_create_options()
        }
        #endif

        var requestURL = url
        var requestHeaders = headers
        var redirects = 0
        var authenticated = false
        while true {
            do {
                let opened = try await Self.open(url: requestURL, headers: requestHeaders, timeoutInterval: timeoutInterval, onEvent: onEvent)
                connection = opened.connection
                core = opened.core
                // The server can send frames in the same segment as its upgrade response.
                core.received(opened.rest, isComplete: false, error: nil)
                return
            } catch let error as LiveKitError {
                guard let response = error.internalError as? WebSocketUpgradeFailure else { throw error }
                if let target = try Self.redirectedURL(response, from: requestURL) {
                    guard redirects < 20 else { throw LiveKitError(.network, internalError: URLError(.httpTooManyRedirects)) }
                    redirects += 1
                    if !authenticated || !Self.isSameOrigin(requestURL, target) {
                        requestHeaders.removeAll { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame }
                    }
                    requestURL = target
                } else if !authenticated, let authorization = Self.basicAuthorization(response, url: requestURL) {
                    authenticated = true
                    requestHeaders.removeAll { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame }
                    requestHeaders.append(("Authorization", authorization))
                } else {
                    throw LiveKitError(.network, internalError: WebSocketUpgradeFailure(statusCode: response.statusCode))
                }
            }
        }
    }

    private static func open(url: URL, headers: [(name: String, value: String)], timeoutInterval: TimeInterval,
                             onEvent: EventHandler?) async throws -> Opened
    {
        guard !Task.isCancelled else { throw LiveKitError(.cancelled) }
        let key = Self.upgradeKey()
        let headers = Self.upgradeHeaders(url: url, headers: headers)
        let request = try Self.upgradeRequest(url: url, key: key, headers: headers)
        let compressionOffered = headers.contains { $0.name.caseInsensitiveCompare("Sec-WebSocket-Extensions") == .orderedSame && $0.value == "permessage-deflate" }
        let connection = NWConnection(to: .url(url), using: Self.makeParameters(secure: url.scheme == "wss",
                                                                                timeoutInterval: timeoutInterval))
        let core = Core(connection: connection, onEvent: onEvent)

        let opening = AsyncCompleter<UpgradeResponse>(label: "WebSocket.open", defaultTimeout: timeoutInterval)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { _ in })
                Self.readUpgradeResponse(connection, url: url, key: key, compressionOffered: compressionOffered, into: opening)
            case let .failed(error), let .waiting(error):
                // `.waiting` too: a connection that cannot be made now fails, as URLSession's did
                // (waitsForConnectivity off); the signal client owns the retries.
                opening.resume(with: .failure(error))
            case .cancelled:
                opening.resume(with: .failure(LiveKitError(.cancelled)))
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
        connection.cancel()
        connection.stateUpdateHandler = nil
    }

    /// Network.framework's errors in the shapes the SDK reads elsewhere (`isNetworkError`, `asTransportError`):
    /// cancellation and timeouts as `URLError`, any other POSIX code as an `NSPOSIXErrorDomain` error.
    static func bridged(_ error: NWError) -> Error {
        switch error {
        case .posix(.ECANCELED):
            URLError(.cancelled)
        case .posix(.ETIMEDOUT):
            URLError(.timedOut)
        case let .posix(code):
            NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue))
        default:
            error
        }
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
}

/// The connection, and what reads, writes and ends it: shared by the socket, its iterators and the callbacks.
private struct Core: Sendable {
    let connection: NWConnection
    let lifecycle = StateSync(Lifecycle())
    let inbox = StateSync(WebSocket.Inbox())
    let onEvent: WebSocket.EventHandler?

    func configure(_ compression: WebSocketCompression?) throws {
        guard let compression else { return }
        let inflater = try WebSocketCompression.Codec(compressing: false, windowBits: compression.serverWindowBits,
                                                      noContextTakeover: compression.serverNoContextTakeover)
        let deflater = try WebSocketCompression.Codec(compressing: true, windowBits: compression.clientWindowBits,
                                                      noContextTakeover: compression.clientNoContextTakeover)
        inbox.mutate { $0.parser = WebSocketFrame.Parser(maximumMessageSize: WebSocket.maximumMessageSize, inflater: inflater) }
        lifecycle.mutate { $0.compressor = deflater }
    }

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
        let (readers, readOn) = inbox.mutate { inbox in
            inbox.ended = true
            inbox.dropUnread()
            defer { inbox.readers.removeAll() }
            // Past the read-ahead limit too: the server's answer comes after whatever it still sends.
            return (inbox.readers, inbox.startReceive())
        }
        for reader in readers {
            reader.resume(returning: .closed)
        }
        if readOn { receiveNext() }
        guard startClosing(code: 1000, finishOnceWritten: false) else { return }
        onEvent?(.closeStarted)
    }

    /// Moves an open socket to closing and writes our close frame, under the lock that every frame is written under, so
    /// that no frame follows it. Every way into closing passes here, so the connection always goes: once the frame is
    /// written if `finishOnceWritten`, on the server's answer otherwise, and at the latest 250 ms on (the JS SDK's wait),
    /// even when the frame waits behind a write that TCP holds up. False when the socket is not open.
    private func startClosing(code: UInt16, finishOnceWritten: Bool) -> Bool {
        guard lifecycle.mutate({
            guard $0.phase == .open else { return false }
            $0.phase = .closing
            connection.send(content: WebSocketFrame.clientClose(code), completion: .contentProcessed { _ in
                if finishOnceWritten { finish() }
            })
            return true
        }) else { return false }
        WebSocket.queue.asyncAfter(deadline: .now() + .milliseconds(250)) {
            finish()
            onEvent?(.closeDeadline)
        }
        return true
    }

    func finish() {
        guard lifecycle.mutate({
            guard $0.phase != .closed else { return false }
            $0.phase = .closed
            return true
        }) else { return }
        onEvent?(.teardown)
        WebSocket.cancel(connection)
    }

    /// Writes `frame` while the socket is open, under the lock that our close frame is written under, so that no
    /// frame follows it. False once the socket is closing.
    @discardableResult
    func write(_ frame: Data, completion: @escaping @Sendable (NWError?) -> Void = { _ in }) -> Bool {
        lifecycle.read { state in
            guard state.phase == .open else { return false }
            connection.send(content: frame, completion: .contentProcessed(completion))
            return true
        }
    }

    func read() async -> WebSocket.Frame {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WebSocket.Frame, Never>) in
                let (frame, readOn) = inbox.mutate { inbox -> (WebSocket.Frame?, Bool) in
                    guard let frame = inbox.take() else {
                        inbox.readers.append(continuation)
                        return (nil, false)
                    }
                    return (frame, inbox.startReceive())
                }
                if let frame { continuation.resume(returning: frame) } else { onEvent?(.receiveRegistered) }
                if readOn { receiveNext() }
            }
        } onCancel: {
            // As the URLSession task's `cancel(with: .normalClosure)`: `SignalClient.cleanUp` cancels the
            // read before it calls `close()`.
            close()
        }
    }

    /// Takes what a TCP read brought: parses it, hands frames to the reads that wait, answers pings and the server's
    /// close frame, and reads on unless ``WebSocket/readAhead`` frames wait unread.
    func received(_ content: Data?, isComplete: Bool, error: NWError?) {
        let (reply, handed, readOn, paused) = inbox.mutate { inbox in
            inbox.receiving = false
            let reply = inbox.ingest(content, isComplete: isComplete, error: error)
            let handed = inbox.handOut()
            let readOn = inbox.startReceive()
            return (reply, handed, readOn, readOn || inbox.done ? nil : inbox.unread)
        }
        for (reader, frame) in handed {
            reader.resume(returning: frame)
        }
        for payload in reply.pongs {
            write(WebSocketFrame.client(opcode: WebSocketFrame.pong, payload))
        }
        if let code = reply.closeCode { answer(code) } else if reply.failed { finish() }
        if readOn { receiveNext() } else if let paused { onEvent?(.readAheadFull(unread: paused)) }
    }

    /// The stream ended with a close frame from the server, or broke the protocol. The server's close frame ends the
    /// handshake when it answers ours; otherwise our close frame goes out with `code`, and the connection with it.
    private func answer(_ code: UInt16) {
        guard startClosing(code: code, finishOnceWritten: true) else { return finish() }
    }

    /// One TCP read at a time, as `Inbox.startReceive()` grants it.
    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { content, _, isComplete, error in
            received(content, isComplete: isComplete, error: error)
        }
    }
}
