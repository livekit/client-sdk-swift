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

    // Upper bounds applied before allocating receive buffers and building outbound frames.
    static let maxMessageSize = 8 * 1024 * 1024 // 8 MB
    static let maxHeaderSize = 64 * 1024 // 64 KB

    enum Error: Swift.Error, Equatable {
        case cancelled
        case corruptMessage
        case socketError(String)
    }

    private let socketFD: Int32

    private let readQueue = DispatchQueue(label: "io.livekit.ipc.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "io.livekit.ipc.write", qos: .userInitiated)

    private let closedLock = NSLock()
    private var _isClosed = false

    // MARK: - Connection

    /// Creates a channel by accepting a connection from the other process.
    init(acceptingOn socketPath: SocketPath) async throws {
        socketFD = try await Self.accept(on: socketPath)
    }

    /// Creates a channel by establishing a connection to the other process.
    init(connectingTo socketPath: SocketPath) async throws {
        socketFD = try await Self.connect(to: socketPath)
    }

    /// For testing: wraps an already-connected blocking file descriptor.
    init(fd: Int32) {
        socketFD = fd
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
        // shutdown() wakes any blocked read() or write() syscall immediately.
        Darwin.shutdown(socketFD, SHUT_RDWR)
        let ioGroup = DispatchGroup()
        readQueue.async(group: ioGroup) {}
        writeQueue.async(group: ioGroup) {}
        ioGroup.notify(queue: .global(qos: .utility)) { [fd = socketFD] in
            Darwin.close(fd)
        }
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

    /// Frame layout: [totalSize][payloadSize][header][payload], all little-endian uint32.
    /// totalSize = header.count + payloadSize, matching the IPCProtocol wire format.
    private func writeFrame(header: Data, payload: Data?) throws {
        let payloadCount = payload?.count ?? 0
        guard header.count > 0, header.count <= Self.maxHeaderSize else {
            throw Error.socketError("outbound header size out of range: \(header.count)")
        }
        let (totalSize, overflow) = header.count.addingReportingOverflow(payloadCount)
        guard !overflow, totalSize <= Self.maxMessageSize else {
            throw Error.socketError("outbound message size out of range")
        }

        var totalSizeLE = UInt32(totalSize).littleEndian
        var payloadSizeLE = UInt32(payloadCount).littleEndian

        var frame = Data()
        frame.reserveCapacity(8 + totalSize)
        withUnsafeBytes(of: &totalSizeLE) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &payloadSizeLE) { frame.append(contentsOf: $0) }
        frame.append(header)
        if let payload { frame.append(payload) }

        try writeAll(frame)
    }

    private func writeAll(_ data: Data) throws {
        // Snapshot fd before entering the loop. close() defers Darwin.close(fd) to this
        // serial queue, so fd remains valid for the entire synchronous duration of this call.
        let fd = socketFD
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                guard !isClosed else { throw Error.cancelled }
                let written = Darwin.write(fd, base, remaining)
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

    /// Reads the next framed message on the dedicated read queue. Returns nil on clean EOF.
    ///
    /// Reads are demand-driven: this is called only when the consumer is ready for the next
    /// message, so the OS socket receive buffer provides natural backpressure to the sender.
    /// No intermediate queue accumulates frames in user space.
    fileprivate func nextFrame() async throws -> (Data, Data?)? {
        guard !isClosed else { return nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Data?)?, Swift.Error>) in
                readQueue.async { [self] in
                    guard !isClosed else {
                        continuation.resume(returning: nil)
                        return
                    }
                    do {
                        let frame = try readFrame()
                        if frame == nil {
                            close()
                        }
                        continuation.resume(returning: frame)
                    } catch {
                        close()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { [self] in
            close()
        }
    }

    /// Reads a single framed message. Returns `nil` on a clean end-of-stream at a frame boundary.
    private func readFrame() throws -> (Data, Data?)? {
        guard let sizeBytes = try readExact(count: 8) else { return nil }
        let totalSize = Int(Self.readUInt32LE(sizeBytes, at: 0))
        let payloadSize = Int(Self.readUInt32LE(sizeBytes, at: 4))

        // Validate peer-supplied sizes before allocating buffers.
        guard payloadSize <= totalSize, totalSize <= Self.maxMessageSize else {
            throw Error.corruptMessage
        }
        let headerSize = totalSize - payloadSize
        guard headerSize > 0, headerSize <= Self.maxHeaderSize else {
            throw Error.corruptMessage
        }

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
        AsyncMessageSequence(channel: self)
    }

    /// An asynchronous sequence of incoming messages.
    ///
    /// The sequence ends when the connection is closed by either side. `next()` is
    /// non-mutating (state lives in the reference-typed `IPCChannel`) so the sequence can be
    /// held and iterated as a `let`, matching the upstream shape used by `BroadcastReceiver`.
    struct AsyncMessageSequence<Header: Decodable>: AsyncSequence, AsyncIteratorProtocol {
        fileprivate let channel: IPCChannel
        private let decoder = PropertyListDecoder()

        func next() async throws -> (Header, Data?)? {
            guard let (headerData, payload) = try await channel.nextFrame() else {
                return nil
            }
            return try (decoder.decode(Header.self, from: headerData), payload)
        }

        func makeAsyncIterator() -> Self { self }
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
            _ = data.copyBytes(to: destination, from: offset ..< (offset + 4))
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
