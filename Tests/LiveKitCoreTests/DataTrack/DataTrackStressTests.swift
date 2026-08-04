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
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Multi-track concurrent-push stress scenarios.
@Suite(.serialized, .tags(.dataTrack, .e2e))
struct DataTrackStressTests {
    /// A multi-track concurrent-push stress scenario.
    struct PushScenario: CustomTestStringConvertible {
        let name: String
        let trackCount: Int
        let framesPerTrack: Int
        let payloadSize: Int
        var testDescription: String { name }

        /// Many small frames across several tracks.
        static let manySmall = PushScenario(name: "manySmall", trackCount: 8, framesPerTrack: 32, payloadSize: 8)
        /// Fewer large multi-packet frames across several tracks.
        static let largeFrames = PushScenario(name: "largeFrames", trackCount: 4, framesPerTrack: 8, payloadSize: 64 * 1024)
    }

    /// A received frame: the stream it arrived on, plus its tagged (track, sequence) header.
    struct ReceivedFrame {
        let stream: Int
        let track: UInt32
        let seq: UInt32
    }

    /// Builds a frame payload tagged with (trackIndex, sequence), padded to `size` bytes.
    private static func makePayload(track: Int, seq: Int, size: Int) -> Data {
        var trackIndex32 = UInt32(track)
        var seq32 = UInt32(seq)
        var data = Data(bytes: &trackIndex32, count: 4)
        data.append(Data(bytes: &seq32, count: 4))
        if size > 8 { data.append(Data(count: size - 8)) }
        return data
    }

    /// Reads the tagged (track, sequence) header from a payload received on `stream`.
    private static func parseFrame(_ payload: Data, stream: Int) -> ReceivedFrame {
        let track = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let seq = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        return ReceivedFrame(stream: stream, track: track, seq: seq)
    }

    /// Publishes several tracks, then pushes every frame on every track at once. Exercises the
    /// Rust manager's per-track send queues and the bridge's packet dispatch under contention.
    /// Each frame is tagged with (trackIndex, sequence); the unreliable channel may drop frames,
    /// but whatever arrives must reach the right track with no duplicates or corruption.
    @Test(arguments: [PushScenario.manySmall, .largeFrames])
    func concurrentPush(_ scenario: PushScenario) async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
            RoomTestingOptions(canSubscribe: true),
        ]) { rooms in
            let framesPerTrack = scenario.framesPerTrack

            // Publish each track and subscribe to it on the remote side.
            var locals: [LocalDataTrack] = []
            var streams: [DataTrackStream] = []
            for i in 0 ..< scenario.trackCount {
                let watcher = DataTrackWatcher(expectedName: "multi-\(i)")
                rooms[1].delegates.add(delegate: watcher)
                try await locals.append(rooms[0].localParticipant.publishDataTrack(name: "multi-\(i)"))
                try await streams.append(watcher.waitForTrack().subscribe())
            }

            // All received frames (flat), drained concurrently with the burst.
            let received = StateSync<[ReceivedFrame]>([])
            var consumers: [Task<Void, Never>] = []
            for (idx, stream) in streams.enumerated() {
                consumers.append(Task {
                    for await frame in stream.values {
                        guard frame.payload.count >= 8 else { continue }
                        let parsed = Self.parseFrame(frame.payload, stream: idx)
                        received.mutate { $0.append(parsed) }
                    }
                })
            }

            // Push every frame on every track concurrently.
            await withTaskGroup(of: Void.self) { group in
                for (trackIndex, track) in locals.enumerated() {
                    for seq in 0 ..< framesPerTrack {
                        let payload = Self.makePayload(track: trackIndex, seq: seq, size: scenario.payloadSize)
                        // try? — a full send queue under the burst is expected, not a failure.
                        group.addTask { try? track.tryPush(frame: DataTrackFrame(payload: payload)) }
                    }
                }
                await group.waitForAll()
            }

            // Let in-flight frames settle, then stop consuming.
            try await Task.sleep(nanoseconds: 3_000_000_000)
            for consumer in consumers {
                consumer.cancel()
            }

            let all = received.copy()
            #expect(!all.isEmpty, "Expected some frames to arrive")
            for streamIndex in 0 ..< scenario.trackCount {
                let frames = all.filter { $0.stream == streamIndex }
                let routedCorrectly = frames.allSatisfy { $0.track == UInt32(streamIndex) }
                let seqs = frames.map(\.seq)
                let noDuplicates = Set(seqs).count == seqs.count
                let inRange = seqs.allSatisfy { $0 < UInt32(framesPerTrack) }
                #expect(routedCorrectly, "Stream \(streamIndex) received a frame from another track")
                #expect(noDuplicates, "Stream \(streamIndex) received a duplicate frame")
                #expect(inRange, "Stream \(streamIndex) received a corrupted sequence")
            }
        }
    }

    // MARK: - Many Tracks

    @Test
    func publishManyTracks() async throws {
        try await TestEnvironment.withRooms([
            RoomTestingOptions(canPublishData: true),
        ]) { rooms in
            let room = rooms[0]
            let count = 64 // Conservative vs Rust's 256 — faster CI.

            var tracks: [LocalDataTrack] = []
            for i in 0 ..< count {
                let track = try await room.localParticipant.publishDataTrack(name: "track-\(i)")
                tracks.append(track)
            }

            #expect(tracks.count == count)
            for (i, track) in tracks.enumerated() {
                #expect(track.info.name == "track-\(i)")
                #expect(track.isPublished)
            }
        }
    }
}
