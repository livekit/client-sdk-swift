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

extension NativeRoomTests {
    @Test(arguments: [true, false])
    func configuredEncryptionEnableIsIdempotent(legacy: Bool) async throws {
        let name = "swift-review-encryption-\(UUID().uuidString)"
        let keyA = BaseKeyProvider(isSharedKey: true, sharedKey: "review-shared-key")
        let keyB = BaseKeyProvider(isSharedKey: true, sharedKey: "review-shared-key")
        let alice = Room(roomOptions: legacy ? .init(e2eeOptions: .init(keyProvider: keyA)) : .init(encryptionOptions: .init(keyProvider: keyA)))
        let bob = Room(roomOptions: legacy ? .init(e2eeOptions: .init(keyProvider: keyB)) : .init(encryptionOptions: .init(keyProvider: keyB)))
        let watcher = ReviewPacketWatcher()
        bob.add(delegate: watcher)
        do {
            try await alice.connect(url: url, token: token("alice", room: name))
            try await bob.connect(url: url, token: token("bob", room: name))
            alice.setE2EEEnabled(true)
            bob.setE2EEEnabled(true)
            // Shared-key mode must ignore the supplied participant identity, including after connect.
            keyA.setKey(key: "review-updated-shared-key", participantId: "ignored")
            keyB.setKey(key: "review-updated-shared-key", participantId: "ignored")
            #expect(keyA.exportKey() == Data("review-updated-shared-key".utf8))
            try await alice.localParticipant.set(metadata: "enabled")
            try await alice.localParticipant.publish(data: Data("enabled".utf8), options: .init(reliable: true))
            #expect(try await watcher.packet.wait() == Data("enabled".utf8))
            alice.setE2EEEnabled(false)
            try await alice.localParticipant.set(metadata: "still allowed")
            try await alice.localParticipant.set(name: "still allowed")
            if legacy {
                try await alice.localParticipant.publish(data: Data("plaintext remains available".utf8))
                try await checkStreams(sender: alice, receiver: bob)
                try await bob.registerRpcMethod("legacy-plaintext") { $0.payload }
                #expect(try await alice.localParticipant.performRpc(destinationIdentity: .init(from: "bob"), method: "legacy-plaintext", payload: "plaintext") == "plaintext")
            } else {
                await #expect(throws: LiveKitError.self) { try await alice.localParticipant.publish(data: Data()) }
            }
            #expect(throws: LiveKitError.self) { try alice.requireNativeSession(forMedia: true) }
            alice.setE2EEEnabled(true)
            try await alice.localParticipant.publish(data: Data("restored".utf8))
            await alice.disconnect()
            await bob.disconnect()
        } catch {
            await alice.disconnect()
            await bob.disconnect()
            throw error
        }
    }

    @Test
    func rpcRegistrationDuringConnectAndConcurrentChanges() async throws {
        let name = "swift-review-rpc-\(UUID().uuidString)"
        let alice = Room()
        let bob = Room()
        let watcher = ConnectingRpcWatcher()
        bob.add(delegate: watcher)
        do {
            try await bob.connect(url: url, token: token("bob", room: name))
            try await watcher.registered.wait()
            try await alice.connect(url: url, token: token("alice", room: name))
            #expect(try await alice.localParticipant.performRpc(destinationIdentity: .init(from: "bob"), method: "connecting", payload: "ready") == "ready")
            let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for _ in 0 ..< 2 {
                    group.addTask {
                        do { try await bob.registerRpcMethod("duplicate") { $0.payload }; return true } catch { #expect(error is LiveKitError); return false }
                    }
                }
                var count = 0
                for await success in group where success {
                    count += 1
                }
                return count
            }
            #expect(successes == 1)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await bob.unregisterRpcMethod("duplicate") }
                group.addTask { try? await bob.registerRpcMethod("duplicate") { _ in "replacement" } }
            }
            await bob.unregisterRpcMethod("duplicate")
            try await bob.registerRpcMethod("duplicate") { _ in "final" }
            #expect(try await alice.localParticipant.performRpc(destinationIdentity: .init(from: "bob"), method: "duplicate", payload: "") == "final")
            try await checkResidualRpcRegistration(caller: alice, receiver: bob)
            await alice.disconnect()
            await bob.disconnect()
        } catch {
            await alice.disconnect()
            await bob.disconnect()
            throw error
        }
    }

    private func checkResidualRpcRegistration(caller: Room, receiver: Room) async throws {
        await receiver.unregisterRpcMethod("duplicate")
        // A native-only registration represents a handler left behind by an unconfirmed removal.
        try await receiver.requireNativeSession().registerRpcMethod(method: "duplicate")
        do {
            _ = try await caller.localParticipant.performRpc(destinationIdentity: .init(from: "bob"), method: "duplicate", payload: "")
            Issue.record("Residual native handler must not reach an unregistered Swift handler")
        } catch let error as RpcError { #expect(error.code == 1400) }
        try await receiver.registerRpcMethod("unrelated") { _ in "unrelated" }
        try await receiver.registerRpcMethod("duplicate") { _ in "reinstalled" }
        #expect(try await caller.localParticipant.performRpc(destinationIdentity: .init(from: "bob"), method: "unrelated", payload: "") == "unrelated")
        #expect(try await caller.localParticipant.performRpc(destinationIdentity: .init(from: "bob"), method: "duplicate", payload: "") == "reinstalled")
    }

    @Test
    func serverRemovalPreservesDisconnectReason() async throws {
        let name = "swift-review-remove-\(UUID().uuidString)"
        let room = Room()
        do {
            try await room.connect(url: url, token: token("removed", room: name))
            let admin = try tokenGenerate(options: .init(videoGrants: .init(roomCreate: false, roomList: false, roomRecord: false, roomAdmin: true, roomJoin: false, room: name, destinationRoom: "", canPublish: false, canSubscribe: false, canPublishData: false, canPublishSources: [], canUpdateOwnMetadata: false, ingressAdmin: false, hidden: false, recorder: false, agent: false)), credentials: .init(key: "devkey", secret: "secret"))
            var components = try #require(URLComponents(string: url))
            components.scheme = components.scheme == "wss" ? "https" : "http"
            components.path = "/twirp/livekit.RoomService/RemoveParticipant"
            var request = try URLRequest(url: #require(components.url))
            request.httpMethod = "POST"
            request.setValue("Bearer \(admin)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["room": name, "identity": "removed"])
            let (_, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            try await eventually { room.connectionState == .disconnected }
            #expect(room.disconnectError?.type == .participantRemoved)
            await room.disconnect()
        } catch {
            await room.disconnect()
            throw error
        }
    }
}

private final class ReviewPacketWatcher: NSObject, RoomDelegate, Sendable {
    let packet = AsyncCompleter<Data>(label: "review packet", defaultTimeout: 10)
    func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic _: String, encryptionType _: LiveKit.EncryptionType) {
        packet.resume(returning: data)
    }
}

private final class ConnectingRpcWatcher: NSObject, RoomDelegate, Sendable {
    let registered = AsyncCompleter<Void>(label: "connecting RPC", defaultTimeout: 10)
    func room(_ room: Room, didUpdateConnectionState state: ConnectionState, from _: ConnectionState) {
        guard state == .connecting else { return }
        Task {
            do {
                #expect(room.connectionState == .connecting)
                try await room.registerRpcMethod("connecting") { $0.payload }
                registered.resume(returning: ())
            } catch { registered.resume(throwing: error) }
        }
    }
}
