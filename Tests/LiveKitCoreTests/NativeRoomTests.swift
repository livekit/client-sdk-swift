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

import Combine
import Foundation
@testable import LiveKit
import LiveKitFFI
import Testing

@Suite(.serialized, TestLimits.unit)
struct NativeRoomTests {
    let url = ProcessInfo.processInfo.environment["LIVEKIT_TESTING_URL"] ?? "ws://127.0.0.1:17891"

    func token(_ identity: String, room: String, canUpdateMetadata: Bool = true) throws -> String {
        try tokenGenerate(options: .init(videoGrants: .init(roomCreate: false, roomList: false, roomRecord: false, roomAdmin: false, roomJoin: true, room: room, destinationRoom: "",
                                                            canPublish: true, canSubscribe: true, canPublishData: true,
                                                            canPublishSources: [], canUpdateOwnMetadata: canUpdateMetadata, ingressAdmin: false, hidden: false, recorder: false, agent: false), identity: identity),
                          credentials: .init(key: "devkey", secret: "secret"))
    }

    func eventually(_ condition: @escaping @Sendable () -> Bool) async throws {
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
            try checkEventValues(#require(alice.nativeRoom.copy()))
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
            #expect(alice.nativeRoom.copy() == nil)
            #expect(bob.nativeRoom.copy() == nil)
        } catch {
            await alice.disconnect()
            await bob.disconnect()
            throw error
        }
    }

    @Test
    func participantObservationAndCallbackOrder() async throws {
        let name = "swift-observation-\(UUID().uuidString)"
        let alice = Room()
        let bob = Room()
        do {
            try await alice.connect(url: url, token: token("alice", room: name))
            try await bob.connect(url: url, token: token("bob", room: name))
            try await eventually { bob.remoteParticipants.count == 1 }
            let participant = try #require(bob.remoteParticipants[.init(from: "alice")])
            let watcher = NameWatcher(participant)
            bob.add(delegate: watcher)
            let observed = StateSync<[String]>([])
            let observation = participant.objectWillChange.sink { [weak participant] in
                if let name = participant?.name { observed.mutate { $0.append(name) } }
            }
            defer { observation.cancel() }
            for name in ["first", "second", "first"] {
                try await alice.localParticipant.set(name: name)
                try await eventually {
                    watcher.names.copy().last == name && observed.copy().contains(name)
                }
                #expect(bob.remoteParticipants[.init(from: "alice")] === participant)
            }
            #expect(watcher.names.copy() == ["first", "second", "first"])
            await alice.disconnect()
            await bob.disconnect()
        } catch {
            await alice.disconnect()
            await bob.disconnect()
            throw error
        }
    }

    @Test
    func rpcErrorsDeadlineAndCancellation() async throws {
        let name = "swift-rpc-errors-\(UUID().uuidString)"
        let caller = Room()
        let receiver = Room()
        let destination = Participant.Identity(from: "receiver")
        do {
            try await caller.connect(url: url, token: token("caller", room: name))
            try await receiver.connect(url: url, token: token("receiver", room: name))
            try await eventually { caller.remoteParticipants.count == 1 }
            try await receiver.registerRpcMethod("custom") { _ in
                throw RpcError(code: 101, message: "custom failure", data: "details")
            }
            for (method, code) in [("custom", 101), ("missing", RpcError.BuiltInError.unsupportedMethod.code)] {
                do {
                    _ = try await caller.localParticipant.performRpc(destinationIdentity: destination, method: method, payload: "")
                    Issue.record("Expected RPC failure")
                } catch let error as RpcError {
                    #expect(error.code == code)
                    if method == "custom" {
                        #expect(error.message == "custom failure")
                        #expect(error.data == "details")
                    }
                }
            }
            let entered = AsyncCompleter<Void>(label: "RPC entered", defaultTimeout: 5)
            let release = AsyncCompleter<String>(label: "RPC release", defaultTimeout: 10)
            try await receiver.registerRpcMethod("wait") { _ in
                entered.resume(returning: ())
                return try await release.wait()
            }
            do {
                _ = try await caller.localParticipant.performRpc(destinationIdentity: destination, method: "wait", payload: "", responseTimeout: 1, maxRoundTripLatency: 0.1)
                Issue.record("Expected RPC deadline")
            } catch let error as RpcError {
                #expect(error.code == RpcError.BuiltInError.responseTimeout.code)
            }
            try await checkRpcCancellation(caller: caller, receiver: receiver, destination: destination, entered: entered, release: release)
            await caller.disconnect()
            await receiver.disconnect()
        } catch {
            await caller.disconnect()
            await receiver.disconnect()
            throw error
        }
    }

    private func checkRpcCancellation(caller: Room, receiver: Room, destination: Participant.Identity,
                                      entered: AsyncCompleter<Void>, release: AsyncCompleter<String>) async throws
    {
        entered.reset()
        let call = Task {
            try await caller.localParticipant.performRpc(destinationIdentity: destination, method: "wait", payload: "")
        }
        try await entered.wait()
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        release.resume(returning: "late")
        try await receiver.registerRpcMethod("echo") { $0.payload }
        #expect(try await caller.localParticipant.performRpc(destinationIdentity: destination, method: "echo", payload: "after cancel") == "after cancel")
    }

    private final class NameWatcher: NSObject, RoomDelegate, Sendable {
        let participant: RemoteParticipant
        let names = StateSync<[String]>([])
        init(_ participant: RemoteParticipant) { self.participant = participant }
        func room(_ room: Room, participant: Participant, didUpdateName name: String) {
            guard name == "first" || name == "second" else { return }
            #expect(participant === self.participant)
            #expect(participant.name == name)
            if let identity = participant.identity {
                #expect(room.remoteParticipants[identity] === participant)
            } else {
                Issue.record("Participant identity missing in name callback")
            }
            names.mutate { $0.append(name) }
        }
    }

    func checkStreams(sender alice: Room, receiver bob: Room, encryption: LiveKit.EncryptionType = .none) async throws {
        let text = AsyncCompleter<String>(label: "native text", defaultTimeout: 10)
        try await bob.registerTextStreamHandler(for: "text") { reader, _ in
            #expect(reader.info.encryptionType == encryption)
            do { try await text.resume(returning: reader.readAll()) } catch { text.resume(throwing: error) }
        }
        _ = try await alice.localParticipant.sendText("stream", for: "text")
        #expect(try await text.wait() == "stream")
        let bytes = AsyncCompleter<Data>(label: "native bytes", defaultTimeout: 10)
        try await bob.registerByteStreamHandler(for: "bytes") { reader, _ in
            #expect(reader.info.encryptionType == encryption)
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
        #expect(room.nativeRoom.copy() == nil)
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
        #expect(room.nativeRoom.copy() == nil)
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
        #expect(room.nativeRoom.copy() == nil)
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

extension NativeRoomTests {
    private func checkEventValues(_ session: FfiRoom) throws {
        var state = NativeRoomState(session.state())
        let participant = try #require(session.state().localParticipant)
        state.applyParticipantEvent(.participantMetadataChanged(participant: participant, oldMetadata: "earlier", metadata: "event metadata"))
        #expect(state.localParticipant?.metadata == "event metadata")
        #expect(participant.metadata() != "event metadata")
        state.applyParticipantEvent(.participantNameChanged(participant: participant, oldName: "earlier", name: "event name"))
        #expect(state.localParticipant?.name == "event name")
        state.applyParticipantEvent(.connectionQualityChanged(participant: participant, quality: .poor))
        #expect(state.localParticipant?.connectionQuality == .poor)
        let remote = try #require(session.state().remoteParticipants.first)
        state.remoteParticipants = []
        state.applyParticipantEvent(.participantsUpdated(participants: [remote]))
        #expect(state.remoteParticipants.isEmpty, "An update cannot insert membership before its join event")
        state.applyParticipantEvent(.participantConnected(participant: remote))
        #expect(state.remoteParticipants.count == 1)
    }
}
