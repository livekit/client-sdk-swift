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

#if os(iOS)

import Darwin
import Foundation

/// A communication channel between two processes on the same machine.
/// Uses a raw UNIX stream socket while preserving the upstream framing API.
final class IPCChannel: @unchecked Sendable, Loggable {
    fileprivate static let connectRetryDelay: TimeInterval = 0.1
    fileprivate static let acceptPollTimeoutMs: Int32 = 200
    fileprivate static let setupQueue = DispatchQueue(label: "io.livekit.ipc.setup", attributes: .concurrent)

    enum Error: Swift.Error {
        case cancelled
        case corruptMessage
        case socketError(String)
    }

    private let socketFD: Int32

    private let readQueue = DispatchQueue(label: "io.livekit.ipc.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "io.livekit.ipc.write", qos: .userInitiated)

    private let messages = MessageQueue()

    private let closedLock = NSLock()
    private var _isClosed = false

    // MARK: - Connection

    /// Creates a channel by accepting a connection from the other process.
    init(acceptingOn socketPath: SocketPath) async throws {
        socketFD = try await Self.accept(on: socketPath)
        startReadLoop()
    }

    /// Creates a channel by establishing a connection to the other process.
    init(connectingTo socketPath: SocketPath) async throws {
        socketFD = try await Self.connect(to: socketPath)
        startReadLoop()
    }

    deinit {
        close()
    }

    /// Whether or not the connection has been closed.
    var isClosed: Bool {
        closedLock.lock()
        defer { closedLock.unlock() }
        return _isClosed
    }

    /// Closes the connection associated with this channel.
    func close() {
        closedLock.lock()
        let alreadyClosed = _isClosed
        _isClosed = true
        closedLock.unlock()

        guard !alreadyClosed else { return }

        log("[IPC] closing channel")
        Darwin.shutdown(socketFD, SHUT_RDWR)
        Darwin.close(socketFD)
        messages.finish()
    }

    // MARK: - Sending

    /// Sends a message to the connected process.
    func send(header: some Encodable, payload: Data? = nil) async throws {
        let encoder = PropertyListEncoder()
        try await send(encodedHeader: encoder.encode(header), payload: payload)
    }

    private func send(encodedHeader: Data, payload: Data?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            writeQueue.async { [self] in
                guard !isClosed else {
                    continuation.resume(throwing: Error.cancelled)
                    return
                }
                do {
                    try writeFrame(header: encodedHeader, payload: payload)
                    continuation.resume()
                } catch {
                    close()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Frame layout: [headerSize][payloadSize][header][payload], little-endian sizes.
    private func writeFrame(header: Data, payload: Data?) throws {
        var headerSize = UInt32(header.count).littleEndian
        var payloadSize = UInt32(payload?.count ?? 0).littleEndian

        var frame = Data()
        frame.reserveCapacity(8 + header.count + (payload?.count ?? 0))
        withUnsafeBytes(of: &headerSize) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &payloadSize) { frame.append(contentsOf: $0) }
        frame.append(header)
        if let payload { frame.append(payload) }

        try writeAll(frame)
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(socketFD, base, remaining)
                if written > 0 {
                    base = base.advanced(by: written)
                    remaining -= written
                } else if written == 0 {
                    throw Error.socketError("connection closed during write")
                } else {
                    if errno == EINTR { continue }
                    throw Error.socketError("write() failed: \(Self.errnoString())")
                }
            }
        }
    }

    // MARK: - Receiving

    private func startReadLoop() {
        readQueue.async { [self] in
            do {
                while let frame = try readFrame() {
                    messages.yield(frame)
                }
            } catch {
                log("[IPC] read loop ended: \(error)", .warning)
            }
            close()
        }
    }

    /// Reads a single framed message. Returns `nil` on a clean end-of-stream at a frame boundary.
    private func readFrame() throws -> (Data, Data?)? {
        guard let sizeBytes = try readExact(count: 8) else { return nil }
        let headerSize = Int(Self.readUInt32LE(sizeBytes, at: 0))
        let payloadSize = Int(Self.readUInt32LE(sizeBytes, at: 4))

        guard let headerData = try readExact(count: headerSize) else {
            throw Error.corruptMessage
        }

        let payloadData: Data?
        if payloadSize > 0 {
            guard let payload = try readExact(count: payloadSize) else {
                throw Error.corruptMessage
            }
            payloadData = payload
        } else {
            payloadData = nil
        }

        return (headerData, payloadData)
    }

    /// Returns `nil` only on clean EOF before reading any byte.
    private func readExact(count: Int) throws -> Data? {
        guard count > 0 else { return Data() }

        var buffer = Data(count: count)
        var total = 0
        var reachedEOF = false

        try buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while total < count {
                let read = Darwin.read(socketFD, base.advanced(by: total), count - total)
                if read > 0 {
                    total += read
                } else if read == 0 {
                    reachedEOF = true
                    return
                } else {
                    if errno == EINTR { continue }
                    throw Error.socketError("read() failed: \(Self.errnoString())")
                }
            }
        }

        if reachedEOF {
            if total == 0 { return nil }
            throw Error.corruptMessage
        }
        return buffer
    }

    /// Receives incoming messages from the connected process.
    /// - Parameter headerType: The type to decode from the message header.
    /// - Returns: An asynchronous sequence for receiving messages as they arrive.
    func incomingMessages<T: Decodable>(_: T.Type) -> AsyncMessageSequence<T> {
        AsyncMessageSequence(upstream: messages)
    }

    /// An asynchronous sequence of incoming messages.
    ///
    /// The sequence ends when the connection is closed by either side. `next()` is
    /// non-mutating (state lives in the reference-typed `MessageQueue`) so the sequence can be
    /// held and iterated as a `let`, matching the upstream shape used by `BroadcastReceiver`.
    struct AsyncMessageSequence<Header: Decodable>: AsyncSequence, AsyncIteratorProtocol {
        fileprivate let upstream: MessageQueue
        private let decoder = PropertyListDecoder()

        func next() async throws -> (Header, Data?)? {
            guard let (headerData, payload) = await upstream.next() else {
                return nil
            }
            return try (decoder.decode(Header.self, from: headerData), payload)
        }

        func makeAsyncIterator() -> Self { self }
    }
}

// MARK: - Message FIFO

/// Minimal single-consumer FIFO for decoded frames.
private final class MessageQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [(Data, Data?)] = []
    private var isFinished = false
    private var waiter: CheckedContinuation<(Data, Data?)?, Never>?

    func yield(_ message: (Data, Data?)) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: message)
        } else {
            buffer.append(message)
            lock.unlock()
        }
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: nil)
        } else {
            lock.unlock()
        }
    }

    func next() async -> (Data, Data?)? {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Data, Data?)?, Never>) in
            lock.lock()
            if !buffer.isEmpty {
                let message = buffer.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
            } else if isFinished {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

// MARK: - Socket setup

private extension IPCChannel {
    /// Runs blocking setup work off the cooperative pool.
    static func runBlocking(_ body: @escaping @Sendable (_ isCancelled: @Sendable () -> Bool) throws -> Int32) async throws -> Int32 {
        let cancelFlag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Swift.Error>) in
                setupQueue.async {
                    do {
                        continuation.resume(returning: try body({ cancelFlag.isCancelled }))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    static func accept(on socketPath: SocketPath) async throws -> Int32 {
        try await runBlocking { isCancelled in
            log("[IPC] listening on \(socketPath.path)")

            let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listenFD >= 0 else {
                throw Error.socketError("socket() failed: \(errnoString())")
            }
            defer { Darwin.close(listenFD) }

            setNoSigPipe(listenFD)

            // Remove stale socket before binding.
            unlink(socketPath.path)

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            try setSunPath(&addr, socketPath.path)

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bindResult = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, addrLen) }
            }
            guard bindResult == 0 else {
                throw Error.socketError("bind() failed: \(errnoString())")
            }
            guard listen(listenFD, 1) == 0 else {
                throw Error.socketError("listen() failed: \(errnoString())")
            }

            setNonBlocking(listenFD)

            while true {
                if isCancelled() { throw Error.cancelled }

                var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
                let pollResult = poll(&pfd, 1, acceptPollTimeoutMs)
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    throw Error.socketError("poll() failed: \(errnoString())")
                }
                if pollResult == 0 { continue }

                let clientFD = Darwin.accept(listenFD, nil, nil)
                if clientFD >= 0 {
                    setBlocking(clientFD)
                    setNoSigPipe(clientFD)
                    log("[IPC] accepted connection")
                    return clientFD
                }
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                throw Error.socketError("accept() failed: \(errnoString())")
            }
        }
    }

    static func connect(to socketPath: SocketPath) async throws -> Int32 {
        try await runBlocking { isCancelled in
            log("[IPC] connecting to \(socketPath.path)")

            while true {
                if isCancelled() { throw Error.cancelled }

                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    throw Error.socketError("socket() failed: \(errnoString())")
                }
                setNoSigPipe(fd)

                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                try setSunPath(&addr, socketPath.path)

                let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let connectResult = withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addrLen) }
                }

                if connectResult == 0 {
                    log("[IPC] connected")
                    return fd
                }

                let connectErrno = errno
                Darwin.close(fd)

                switch connectErrno {
                case ENOENT, ECONNREFUSED, EAGAIN, EINTR, ETIMEDOUT:
                    Thread.sleep(forTimeInterval: connectRetryDelay)
                    continue
                default:
                    throw Error.socketError("connect() failed: \(errnoString(connectErrno))")
                }
            }
        }
    }

    // MARK: - Socket helpers

    static func setNoSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    static func setBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    }

    static func setSunPath(_ addr: inout sockaddr_un, _ path: String) throws {
        let pathBytes = path.utf8CString // includes the null terminator
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else {
            throw Error.socketError("socket path too long: \(path)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePointer in
            tuplePointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                pathBytes.withUnsafeBufferPointer { source in
                    destination.update(from: source.baseAddress!, count: source.count)
                }
            }
        }
    }

    static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { destination in
            data.copyBytes(to: destination, from: offset ..< (offset + 4))
        }
        return UInt32(littleEndian: value)
    }

    static func errnoString(_ code: Int32 = errno) -> String {
        String(cString: strerror(code))
    }
}

/// Thread-safe cancellation flag for blocking setup.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

#endif
