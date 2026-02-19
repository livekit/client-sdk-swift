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

@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
import Network

struct IPCChannelTests: Sendable {
    private let socketPath: SocketPath

    enum TestSetupError: Error {
        case failedToGeneratePath
    }

    init() throws {
        // Use relative paths to ensure socket path is not too long
        let temporaryDirectory = FileManager.default.temporaryDirectory
        FileManager.default.changeCurrentDirectoryPath(temporaryDirectory.path)

        guard let socketPath = SocketPath(UUID().uuidString + ".sock") else {
            throw TestSetupError.failedToGeneratePath
        }
        self.socketPath = socketPath
    }

    @Test func connectionAcceptorFirst() async throws {
        try await confirmation("Connection established") { established in
            Task {
                let channel = try await IPCChannel(acceptingOn: socketPath)
                #expect(!channel.isClosed)

                established()
            }
            Task {
                let channel = try await IPCChannel(connectingTo: socketPath)
                #expect(!channel.isClosed)

                // Keep alive to give time acceptor to accept
                try await Task.shortSleep()
            }
        }
    }

    @Test func connectionConnectorFirst() async throws {
        try await confirmation("Connection established") { established in
            Task {
                let channel = try await IPCChannel(connectingTo: socketPath)
                #expect(!channel.isClosed)
                established()
            }
            Task {
                let channel = try await IPCChannel(acceptingOn: socketPath)
                #expect(!channel.isClosed)
            }
        }
    }

    private func assertInitCancellationThrows(
        _ initializer: @Sendable @escaping @autoclosure () async throws -> IPCChannel,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await confirmation("Throws error on cancellation") { cancelThrowsError in
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
        }
    }

    // swiftformat:disable redundantSelf hoistAwait
    @Test func connectorCancelDuringInit() async throws {
        try await assertInitCancellationThrows(
            await IPCChannel(connectingTo: self.socketPath)
        )
    }

    @Test func acceptorCancelDuringInit() async throws {
        try await assertInitCancellationThrows(
            await IPCChannel(acceptingOn: self.socketPath)
        )
    }

    // swiftformat:enable all

    private struct TestHeader: Codable, Equatable {
        let someField: Int
    }

    @Test func messageExchange() async throws {
        let testHeader = TestHeader(someField: 1)
        let testPayload = Data([1, 2, 3])

        try await confirmation(expectedCount: 2) { received in
            Task {
                let channel = try await IPCChannel(acceptingOn: socketPath)

                for try await (header, payload) in channel.incomingMessages(TestHeader.self) {
                    // Received initial message
                    #expect(header == testHeader)
                    #expect(payload == testPayload)
                    received()

                    // Send reply
                    try await channel.send(header: testHeader, payload: testPayload)
                }
            }
            Task {
                let channel = try await IPCChannel(connectingTo: socketPath)

                // Send initial message
                try await channel.send(header: testHeader, payload: testPayload)

                for try await (header, payload) in channel.incomingMessages(TestHeader.self) {
                    // Received reply
                    #expect(header == testHeader)
                    #expect(payload == testPayload)
                    received()
                }
            }
        }
    }

    @Test func messageSequenceAfterClosure() async throws {
        try await confirmation("Message sequence ends after closure") { sequenceEnds in
            Task {
                let channel = try await IPCChannel(acceptingOn: socketPath)
                for try await _ in channel.incomingMessages(TestHeader.self) {
                    // Received message
                }
                sequenceEnds()
            }
            Task {
                let channel = try await IPCChannel(connectingTo: socketPath)
                try await channel.send(header: TestHeader(someField: 1))
                channel.close()
            }
        }
    }
}

private extension Task where Success == Never, Failure == Never {
    static func shortSleep() async throws {
        try await sleep(nanoseconds: 1_000_000_000)
    }
}

#endif
