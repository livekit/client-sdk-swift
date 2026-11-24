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
import LiveKitFFI
import Testing

@Suite(.serialized, TestLimits.unit)
struct NativeRoomTests {
    private let url = ProcessInfo.processInfo.environment["LIVEKIT_TESTING_URL"] ?? "ws://127.0.0.1:17891"

    private func token(_ identity: String, room: String) throws -> String {
        try tokenGenerate(options: .init(videoGrants: .init(roomCreate: false, roomList: false, roomRecord: false, roomAdmin: false, roomJoin: true, room: room, destinationRoom: "",
                                                            canPublish: true, canSubscribe: true, canPublishData: true,
                                                            canPublishSources: [], canUpdateOwnMetadata: true, ingressAdmin: false, hidden: false, recorder: false, agent: false), identity: identity),
                          credentials: .init(key: "devkey", secret: "secret"))
    }

    private func eventually(_ condition: @escaping @Sendable () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw LiveKitError(.timedOut, message: "Native projection did not reach expected state")
    }

    @Test
    func productionRoomLifecycle() async throws {
        let name = "swift-native-\(UUID().uuidString)"
        let alice = Room()
        let bob = Room()
        let aliceToken = try token("alice", room: name)
        let bobToken = try token("bob", room: name)
        let received = AsyncCompleter<Data>(label: "native data", defaultTimeout: 10)
        let watcher = DataWatcher(received)
        bob.add(delegate: watcher)
        do {
            try await alice.connect(url: url, token: aliceToken)
            try await bob.connect(url: url, token: bobToken)
            try await eventually { alice.remoteParticipants.count == 1 && bob.remoteParticipants.count == 1 }
            let remoteAlice = try #require(bob.remoteParticipants[.init(from: "alice")])
            #expect(alice.connectionState == .connected)
            #expect(alice.localParticipant.identity?.stringValue == "alice")
            #expect(try await alice.sid() == bob.sid())
            try await alice.localParticipant.set(name: "Alice updated")
            try await alice.localParticipant.set(metadata: "metadata")
            try await alice.localParticipant.set(attributes: ["key": "value"])
            try await eventually { remoteAlice.name == "Alice updated" && remoteAlice.metadata == "metadata" && remoteAlice.attributes["key"] == "value" }
            #expect(bob.remoteParticipants[.init(from: "alice")] === remoteAlice)
            try await alice.localParticipant.publish(data: Data("real Rust transport".utf8), options: .init(topic: "proof", reliable: true))
            #expect(try await received.wait() == Data("real Rust transport".utf8))
            try await bob.registerRpcMethod("echo") { $0.payload }
            #expect(try await alice.localParticipant.performRpc(destinationIdentity: .init(from: "bob"), method: "echo", payload: "rpc") == "rpc")
            try await checkStreams(sender: alice, receiver: bob)
            await alice.disconnect()
            try await eventually { bob.remoteParticipants.isEmpty }
            #expect(alice.connectionState == .disconnected)
            #expect(alice.localParticipant.identity == nil)
            try await alice.connect(url: url, token: aliceToken)
            try await eventually { bob.remoteParticipants.count == 1 }
            #expect(bob.remoteParticipants[.init(from: "alice")] !== remoteAlice)
            #expect(try await alice.localParticipant.performRpc(destinationIdentity: .init(from: "bob"), method: "echo", payload: "rejoin") == "rejoin")
            await alice.disconnect()
            await bob.disconnect()
            #expect(alice.nativeSession.copy() == nil)
            #expect(bob.nativeSession.copy() == nil)
        } catch {
            await alice.disconnect()
            await bob.disconnect()
            throw error
        }
    }

    private func checkStreams(sender alice: Room, receiver bob: Room) async throws {
        let text = AsyncCompleter<String>(label: "native text", defaultTimeout: 10)
        try await bob.registerTextStreamHandler(for: "text") { reader, _ in
            do { try await text.resume(returning: reader.readAll()) } catch { text.resume(throwing: error) }
        }
        _ = try await alice.localParticipant.sendText("stream", for: "text")
        #expect(try await text.wait() == "stream")
        let bytes = AsyncCompleter<Data>(label: "native bytes", defaultTimeout: 10)
        try await bob.registerByteStreamHandler(for: "bytes") { reader, _ in
            do { try await bytes.resume(returning: reader.readAll()) } catch { bytes.resume(throwing: error) }
        }
        _ = try await alice.localParticipant.sendBytes(Data([1, 2, 3]), for: "bytes")
        #expect(try await bytes.wait() == Data([1, 2, 3]))
    }

    @Test
    func invalidTokenUnsupportedOptionsAndCancellation() async throws {
        let room = Room()
        await #expect(throws: LiveKitError.self) { try await room.connect(url: url, token: "invalid") }
        #expect(room.connectionState == .disconnected)
        #expect(room.nativeSession.copy() == nil)
        let validToken = try token("cancel", room: "swift-native-\(UUID().uuidString)")
        await #expect(throws: LiveKitError.self) {
            try await room.connect(url: url, token: validToken, connectOptions: .init(reconnectAttempts: 3))
        }
        let task = Task {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch {}
            try await room.connect(url: url, token: validToken)
        }
        task.cancel()
        _ = await task.result
        #expect(room.nativeSession.copy() == nil)
        try await room.connect(url: url, token: validToken)
        let cleanup = Task {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch {}
            await room.disconnect()
        }
        cleanup.cancel()
        async let alsoDisconnect: Void = room.disconnect()
        await cleanup.value
        await alsoDisconnect
        #expect(room.connectionState == .disconnected)
        #expect(room.nativeSession.copy() == nil)
    }

    @Test
    func releasingConnectedRoomReleasesNativeDriver() async throws {
        func connectAndDrop() async throws -> @Sendable () -> Bool {
            let room = Room()
            let token = try token("release", room: "swift-native-\(UUID().uuidString)")
            try await room.connect(url: url, token: token)
            return { [weak room, weak driver = room.nativeDriver] in room == nil && driver == nil }
        }
        let released = try await connectAndDrop()
        try await eventually(released)
    }

    private final class DataWatcher: NSObject, RoomDelegate, Sendable {
        let received: AsyncCompleter<Data>
        init(_ received: AsyncCompleter<Data>) { self.received = received }
        func room(_: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: LiveKit.EncryptionType) {
            if topic == "proof", participant?.identity?.stringValue == "alice", encryptionType == .none {
                received.resume(returning: data)
            }
        }
    }
}
