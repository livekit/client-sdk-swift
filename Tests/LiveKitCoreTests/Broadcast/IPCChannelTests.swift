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
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.tags(.broadcast))
struct IPCChannelTests {
    private let socketPath: SocketPath

    enum TestSetupError: Error {
        case failedToGeneratePath
        case socketPairFailed
    }

    init() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        FileManager.default.changeCurrentDirectoryPath(temporaryDirectory.path)

        guard let socketPath = SocketPath(UUID().uuidString + ".sock") else {
            throw TestSetupError.failedToGeneratePath
        }
        self.socketPath = socketPath
    }

    // MARK: - Connection tests

    @Test func connectionAcceptorFirst() async {
        await confirmation("Connection established") { established in
            let acceptTask = Task {
                let channel = try await IPCChannel(acceptingOn: socketPath)
                #expect(!channel.isClosed)
                established()
            }.cancellable()
            let connectTask = Task {
                let channel = try await IPCChannel(connectingTo: socketPath)
                #expect(!channel.isClosed)
                try await Task.shortSleep()
            }.cancellable()
            defer {
                acceptTask.cancel()
                connectTask.cancel()
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    @Test func connectionConnectorFirst() async {
        await confirmation("Connection established") { established in
            let connectTask = Task {
                let channel = try await IPCChannel(connectingTo: socketPath)
                #expect(!channel.isClosed)
                established()
            }.cancellable()
            let acceptTask = Task {
                let channel = try await IPCChannel(acceptingOn: socketPath)
                #expect(!channel.isClosed)
            }.cancellable()
            defer {
                connectTask.cancel()
                acceptTask.cancel()
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func assertInitCancellationThrows(
        _ initializer: @Sendable @escaping @autoclosure () async throws -> IPCChannel,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) async throws {
        await confirmation("Throws error on cancellation") { cancelThrowsError in
            let channelTask = Task {
                do {
                    _ = try await initializer()
                    Issue.record("Should not pass initialization with no connection", sourceLocation: sourceLocation)
                } catch {
                    #expect(error as? IPCChannel.Error == .cancelled, sourceLocation: sourceLocation)
                    cancelThrowsError()
                }
            }
            channelTask.cancel()
            _ = await channelTask.result
        }
    }

    // swiftformat:disable redundantSelf hoistAwait
    @Test func connectorCancelDuringInit() async throws {
        try await assertInitCancellationThrows(
            await IPCChannel(connectingTo: self.socketPath),
        )
    }

    @Test func acceptorCancelDuringInit() async throws {
        try await assertInitCancellationThrows(
            await IPCChannel(acceptingOn: self.socketPath),
        )
    }

    // swiftformat:enable all

    // MARK: - Message exchange tests

    private struct TestHeader: Codable, Equatable {
        let someField: Int
    }

    @Test func messageExchange() async {
        let testHeader = TestHeader(someField: 1)
        let testPayload = Data([1, 2, 3])

        await confirmation(expectedCount: 2) { received in
            // Fire-and-forget Tasks (matching original XCTest pattern):
            // The `for try await` loops are infinite until the channel closes.
            // confirmation returns once expectedCount is reached; Tasks are
            // cancelled via defer.
            let acceptTask = Task {
                let channel = try await IPCChannel(acceptingOn: socketPath)

                for try await (header, payload) in channel.incomingMessages(TestHeader.self) {
                    #expect(header == testHeader)
                    #expect(payload == testPayload)
                    received()
                    try await channel.send(header: testHeader, payload: testPayload)
                }
            }.cancellable()
            let connectTask = Task {
                let channel = try await IPCChannel(connectingTo: socketPath)
                try await channel.send(header: testHeader, payload: testPayload)

                for try await (header, payload) in channel.incomingMessages(TestHeader.self) {
                    #expect(header == testHeader)
                    #expect(payload == testPayload)
                    received()
                }
            }.cancellable()
            defer {
                acceptTask.cancel()
                connectTask.cancel()
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    @Test func messageSequenceAfterClosure() async {
        await confirmation("Message sequence ends after closure") { sequenceEnds in
            let acceptTask = Task {
                let channel = try await IPCChannel(acceptingOn: socketPath)
                for try await _ in channel.incomingMessages(TestHeader.self) {
                    // Received message
                }
                sequenceEnds()
            }.cancellable()
            let sendTask = Task {
                let channel = try await IPCChannel(connectingTo: socketPath)
                try await channel.send(header: TestHeader(someField: 1))
                channel.close()
            }.cancellable()
            defer {
                acceptTask.cancel()
                sendTask.cancel()
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    // MARK: - Framing format (#6)

    /// Verifies [totalSize][payloadSize][header][payload] wire layout.
    /// totalSize must equal header.count + payload.count.
    @Test func framingFormat() async throws {
        // fd[0] = sender (wrap in IPCChannel), fd[1] = raw reader.
        let (senderFD, rawReaderFD) = try makePair()
        defer { Darwin.close(rawReaderFD) }

        let sender = IPCChannel(fd: senderFD)
        defer { sender.close() }

        let header = TestHeader(someField: 42)
        let payload = Data(repeating: 0xAB, count: 16)
        let encodedHeader = try PropertyListEncoder().encode(header)

        try await sender.send(header: header, payload: payload)

        // Read the 8-byte size prefix from the raw fd (blocking).
        var sizePrefix = [UInt8](repeating: 0, count: 8)
        let n = Darwin.read(rawReaderFD, &sizePrefix, 8)
        #expect(n == 8, "Expected to read 8 size-prefix bytes")

        let totalSize = Int(readLE32(sizePrefix, at: 0))
        let payloadSize = Int(readLE32(sizePrefix, at: 4))
        let headerSize = totalSize - payloadSize

        #expect(payloadSize == payload.count, "payloadSize field must equal payload byte count")
        #expect(headerSize == encodedHeader.count, "derived headerSize must equal plist-encoded header size")
        #expect(totalSize == encodedHeader.count + payload.count, "totalSize must equal header + payload")
    }

    // MARK: - Frame size validation (#7)

    /// payloadSize > totalSize → corruptMessage.
    @Test func receivePayloadSizeExceedsTotalSize() async throws {
        // totalSize=10, payloadSize=20: violates payloadSize <= totalSize.
        try await expectCorruptMessage(sizePrefix: (10, 20), body: Data(count: 10))
    }

    /// totalSize > maxMessageSize → corruptMessage.
    @Test func receiveTotalSizeExceedsMax() async throws {
        let over = IPCChannel.maxMessageSize + 1
        // Only send the 8-byte header; receiver should reject on size alone.
        try await expectCorruptMessage(sizePrefix: (over, 0), body: Data())
    }

    /// headerSize == 0 (totalSize == payloadSize) → corruptMessage.
    @Test func receiveHeaderSizeZero() async throws {
        // totalSize == payloadSize == 4 → headerSize = 0, which is invalid.
        try await expectCorruptMessage(sizePrefix: (4, 4), body: Data(count: 4))
    }

    /// headerSize > maxHeaderSize → corruptMessage.
    @Test func receiveHeaderSizeExceedsMax() async throws {
        let bigHeader = IPCChannel.maxHeaderSize + 1
        // totalSize = bigHeader, payloadSize = 0 → headerSize = bigHeader.
        try await expectCorruptMessage(sizePrefix: (bigHeader, 0), body: Data())
    }

    @Test func outboundOversizedFrameDoesNotCloseChannel() async throws {
        let (senderFD, rawReaderFD) = try makePair()
        let sender = IPCChannel(fd: senderFD)
        defer {
            sender.close()
            Darwin.close(rawReaderFD)
        }

        do {
            try await sender.send(
                header: TestHeader(someField: 1),
                payload: Data(repeating: 0xAB, count: IPCChannel.maxMessageSize),
            )
            Issue.record("Expected outboundFrameTooLarge")
        } catch let error as IPCChannel.Error {
            #expect(error == .outboundFrameTooLarge)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(!sender.isClosed)

        try await sender.send(header: TestHeader(someField: 2), payload: Data([1, 2, 3]))

        var prefix = [UInt8](repeating: 0, count: 8)
        let readCount = Darwin.read(rawReaderFD, &prefix, prefix.count)
        #expect(readCount == prefix.count)
        #expect(readLE32(prefix, at: 4) == 3)
    }

    /// Truncated size prefix (only 4 of 8 bytes, then EOF) → error.
    @Test func receiveTruncatedSizePrefix() async throws {
        let (channelFD, rawWriterFD) = try makePair()
        let channel = IPCChannel(fd: channelFD)
        defer { channel.close() }

        // Write only 4 bytes then close — EOF mid-prefix.
        Darwin.write(rawWriterFD, [0x01, 0x00, 0x00, 0x00] as [UInt8], 4)
        Darwin.close(rawWriterFD)

        var gotError = false
        do {
            for try await _ in channel.incomingMessages(TestHeader.self) {}
        } catch {
            gotError = true
        }
        #expect(gotError, "Expected an error for truncated size prefix")
    }

    // MARK: - Lifecycle tests (#8)

    @Test func multipleCloseIsSafe() throws {
        let (fdA, fdB) = try makePair()
        defer { Darwin.close(fdB) }
        let channel = IPCChannel(fd: fdA)
        channel.close()
        channel.close()
        channel.close()
        #expect(channel.isClosed)
    }

    @Test func isClosedAfterPeerEOF() async {
        await confirmation("Sequence ends on peer EOF") { done in
            let acceptTask = Task {
                let channel = try await IPCChannel(acceptingOn: socketPath)
                for try await _ in channel.incomingMessages(TestHeader.self) {}
                #expect(channel.isClosed)
                done()
            }.cancellable()
            let connectTask = Task {
                let channel = try await IPCChannel(connectingTo: socketPath)
                channel.close()
            }.cancellable()
            defer { acceptTask.cancel(); connectTask.cancel() }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    // MARK: - Cancellation tests (#9)

    @Test func taskCancellationWakesRead() async throws {
        let (channelFD, rawWriterFD) = try makePair()
        let channel = IPCChannel(fd: channelFD)
        defer { Darwin.close(rawWriterFD) }

        await confirmation("Read loop exits after task cancellation") { done in
            let readTask = Task {
                for try await _ in channel.incomingMessages(TestHeader.self) {}
                done()
            }

            // Give the task time to enter the blocking read.
            try? await Task.sleep(nanoseconds: 50_000_000)
            readTask.cancel()
            _ = await readTask.result
        }

        #expect(channel.isClosed, "Channel must be closed after task cancellation")
    }

    // MARK: - Helpers

    /// Creates a connected socket pair via socketpair(). Both fds are blocking.
    private func makePair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        let result = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        guard result == 0 else { throw TestSetupError.socketPairFailed }
        return (fds[0], fds[1])
    }

    /// Writes an 8-byte malformed size prefix + body, then expects the channel to throw corruptMessage.
    private func expectCorruptMessage(sizePrefix: (Int, Int), body: Data) async throws {
        let (channelFD, rawWriterFD) = try makePair()
        let channel = IPCChannel(fd: channelFD)
        defer { channel.close() }

        // Write size header.
        var totalSizeLE = UInt32(sizePrefix.0 & 0xFFFF_FFFF).littleEndian
        var payloadSizeLE = UInt32(sizePrefix.1 & 0xFFFF_FFFF).littleEndian
        withUnsafeBytes(of: &totalSizeLE) { raw in _ = Darwin.write(rawWriterFD, raw.baseAddress!, 4) }
        withUnsafeBytes(of: &payloadSizeLE) { raw in _ = Darwin.write(rawWriterFD, raw.baseAddress!, 4) }
        if !body.isEmpty {
            body.withUnsafeBytes { raw in
                if let base = raw.baseAddress { Darwin.write(rawWriterFD, base, raw.count) }
            }
        }
        Darwin.close(rawWriterFD)

        do {
            for try await _ in channel.incomingMessages(TestHeader.self) {}
            Issue.record("Expected corruptMessage but got no error")
        } catch let err as IPCChannel.Error {
            #expect(err == .corruptMessage)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    /// Reads a little-endian UInt32 from a byte array.
    private func readLE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { dest in
            dest.copyBytes(from: bytes[offset ..< (offset + 4)])
        }
        return UInt32(littleEndian: value)
    }
}

private extension Task where Success == Never, Failure == Never {
    static func shortSleep() async throws {
        try await sleep(nanoseconds: 1_000_000_000)
    }
}

#endif
