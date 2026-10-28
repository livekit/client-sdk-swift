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

import Benchmark
import Foundation
import LiveKit

// BM-SESSION: End-to-end session lifecycle.
//
// Where BM-CONN decomposes `connect()` into its internal phases, this measures the milestones a
// user actually waits for, across two participants in one room. Each iteration runs a whole
// session so every metric comes from the same connection, making the phase sums meaningful
// per-run rather than only in aggregate.
//
// Metrics, all wall-clock milliseconds:
//   connect_ms                 `room.connect()` on the publisher, call to return.
//   peer_visible_ms            Subscriber `connect()` call → publisher's delegate reports it.
//                              Includes the subscriber's own connect: it is the delay before an
//                              already-present peer can see a joiner at all.
//   pub_to_sub_ms              `publish(videoTrack:)` call → subscriber's didSubscribeTrack.
//   first_frame_ms             didSubscribeTrack → first frame at the subscriber's renderer.
//                              Media flowing on an already-established transport, so it is small;
//                              a large value means the transport, not signalling, is the problem.
//   publish_to_first_frame_ms  publish call → first frame. The end-to-end figure; ≈ the two above.
//   data_rtt_ms                Publisher sends on a topic → echo participant echoes → publisher
//                              receives. A full application-level round trip over the data channel.
//   disconnect_ms              `room.disconnect()` on the publisher, call to return.
//
// Variants mirror BM-CONN so a run can be compared across transport modes:
//   BM-SESSION-001: Dual PeerConnection (default)
//   BM-SESSION-002: Single PeerConnection

private let mConnect: BenchmarkMetric = .custom("connect_ms", polarity: .prefersSmaller, useScalingFactor: false)
private let mPeerVisible: BenchmarkMetric = .custom("peer_visible_ms", polarity: .prefersSmaller, useScalingFactor: false)
private let mPubToSub: BenchmarkMetric = .custom("pub_to_sub_ms", polarity: .prefersSmaller, useScalingFactor: false)
private let mFirstFrame: BenchmarkMetric = .custom("first_frame_ms", polarity: .prefersSmaller, useScalingFactor: false)
private let mPubToFrame: BenchmarkMetric = .custom("publish_to_first_frame_ms", polarity: .prefersSmaller, useScalingFactor: false)
private let mDataRtt: BenchmarkMetric = .custom("data_rtt_ms", polarity: .prefersSmaller, useScalingFactor: false)
private let mDisconnect: BenchmarkMetric = .custom("disconnect_ms", polarity: .prefersSmaller, useScalingFactor: false)

/// 1 per iteration that never reached a milestone, 0 per iteration that completed. See the same
/// metric in BM-JOIN: an arm that intermittently fails must not read as a reliable one with
/// fewer samples.
private let mFailed: BenchmarkMetric = .custom("failed_iterations", polarity: .prefersSmaller, useScalingFactor: false)

private let sessionMetrics = [mConnect, mPeerVisible, mPubToSub, mFirstFrame, mPubToFrame, mDataRtt, mDisconnect, mFailed]

let sessionLifecycleBenchmarks: @Sendable () -> Void = {
    for (name, singlePC) in [("BM-SESSION-001-DualPC", false), ("BM-SESSION-002-SinglePC", true)] {
        Benchmark(
            name,
            configuration: .init(
                // `.default` would add wall clock for the whole iteration, which spans two
                // connects, a publish and a teardown — a number no user waits for. The named
                // milestones below are the measurement.
                metrics: sessionMetrics,
                timeUnits: .milliseconds,
                units: Dictionary(uniqueKeysWithValues: sessionMetrics.map { ($0, BenchmarkUnits.count) }),
                warmupIterations: 2,
                scalingFactor: .one,
                maxDuration: .seconds(600),
                maxIterations: 15,
            ),
        ) { benchmark in
            let config = BenchmarkConfig.fromEnvironment()
            let tokenGen = TokenGenerator(apiKey: config.apiKey, apiSecret: config.apiSecret)

            for _ in benchmark.scaledIterations {
                // Buffered so a session that fails late contributes nothing at all, rather than
                // the milestones it happened to reach before failing.
                let samples = MeasurementBuffer()
                let failure = await runTolerantly {
                    try await runSession(benchmark: benchmark,
                                         samples: samples,
                                         config: config,
                                         tokenGen: tokenGen,
                                         singlePC: singlePC)
                }
                if failure == nil { samples.commit(to: benchmark) }
                reportFailure(failure, variant: name)
                benchmark.measurement(mFailed, failure == nil ? 0 : 1)
                // Rooms are torn down; give the SFU a beat before the next identity joins.
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

/// One publisher/subscriber session, emitting every lifecycle metric from a single connection.
private func runSession(benchmark _: Benchmark,
                        samples: MeasurementBuffer,
                        config: BenchmarkConfig,
                        tokenGen: TokenGenerator,
                        singlePC: Bool) async throws
{
    let roomOptions = RoomOptions(singlePeerConnection: singlePC)
    let roomName = "benchmark-session-\(UUID().uuidString.prefix(8))"
    let dataTopic = "bench-echo"

    let peerVisible = PeerVisibleObserver()
    let dataEcho = DataEchoObserver(topic: dataTopic)
    let subscriberObserver = SubscriberObserver()

    let publisher = Room(roomOptions: roomOptions)
    publisher.delegates.add(delegate: peerVisible)
    publisher.delegates.add(delegate: dataEcho)

    let subscriber = Room(roomOptions: roomOptions)
    subscriber.delegates.add(delegate: subscriberObserver)

    // Echoes the publisher's data back so the round trip is a real application hop rather than a
    // server-side reflection.
    let echoDelegate = EchoBackDelegate(room: subscriber, topic: dataTopic)
    subscriber.delegates.add(delegate: echoDelegate)

    defer {
        // Keep the observers alive for the whole session; `delegates` holds them weakly.
        _ = (peerVisible, dataEcho, subscriberObserver, echoDelegate)
    }

    do {
        // connect_ms — the publisher joins an empty room.
        let connectStart = nowMs()
        try await publisher.connect(url: config.url,
                                    token: tokenGen.generate(roomName: roomName, identity: "bench-pub"))
        samples.record(mConnect, Int(nowMs() - connectStart))

        // peer_visible_ms — from the subscriber starting its connect to the publisher seeing it.
        let peerStart = nowMs()
        try await subscriber.connect(url: config.url,
                                     token: tokenGen.generate(roomName: roomName, identity: "bench-sub"))
        let visibleAt = try await peerVisible.visible.wait()
        samples.record(mPeerVisible, Int(visibleAt - peerStart))

        // pub_to_sub_ms / first_frame_ms / publish_to_first_frame_ms
        let frameFeeder = try await measurePublishToFirstFrame(samples: samples,
                                                               publisher: publisher,
                                                               observer: subscriberObserver,
                                                               singlePC: singlePC)
        defer { frameFeeder.cancel() }

        // data_rtt_ms — publisher → subscriber → publisher.
        let rttStart = nowMs()
        try await publisher.localParticipant.publish(data: Data("ping".utf8),
                                                     options: DataPublishOptions(topic: dataTopic))
        let echoedAt = try await dataEcho.received.wait()
        samples.record(mDataRtt, Int(echoedAt - rttStart))

        // disconnect_ms — publisher teardown only; the subscriber is closed outside the measurement.
        let disconnectStart = nowMs()
        await publisher.disconnect()
        samples.record(mDisconnect, Int(nowMs() - disconnectStart))

        await subscriber.disconnect()
    } catch {
        // Spelled out because `defer` cannot await. Without it a thrown milestone leaves two
        // connected Rooms — live peer connections, an audio device module — running for the rest
        // of the benchmark, so every later iteration measures on a progressively busier host.
        // Deliberately unmeasured: this is cleanup, not the teardown `disconnect_ms` reports.
        await publisher.disconnect()
        await subscriber.disconnect()
        throw error
    }
}

/// Publishes a video track into the established session and records the three milestones that
/// follow, returning the feeder task so the caller can stop it with the rest of the session.
///
/// Split out from ``runSession(benchmark:config:tokenGen:singlePC:)`` because the publish-to-frame
/// leg is the one under investigation and reads better whole.
private func measurePublishToFirstFrame(samples: MeasurementBuffer,
                                        publisher: Room,
                                        observer: SubscriberObserver,
                                        singlePC: Bool) async throws -> Task<Void, Never>
{
    // Camera source explicitly: `createBufferTrack` defaults to `.screenShareVideo`, which
    // selects screen-share encoder presets and an uncapped start bitrate — not what a call
    // publishes, and not what the rust and JS harnesses use.
    let track = await LocalVideoTrack.createBufferTrack(name: "camera",
                                                        source: .camera,
                                                        options: BufferCaptureOptions())
    let frameFeeder = startFeedingFrames(into: track)

    do {
        let publishStart = nowMs()
        try await publisher.localParticipant.publish(videoTrack: track)
        // Splits the publisher's own negotiation off the subscriber's: `publish` returns once the
        // track is published, so anything after this is the subscribe path, not the publish path.
        let publishedAt = nowMs()
        let subscribedAt = try await observer.subscribed.wait()
        let firstFrameAt = try await observer.firstFrame.wait()

        samples.record(mPubToSub, Int(subscribedAt - publishStart))
        samples.record(mFirstFrame, Int(firstFrameAt - subscribedAt))
        samples.record(mPubToFrame, Int(firstFrameAt - publishStart))

        Timeline.mark(singlePC ? "SinglePC" : "DualPC", [
            ("publish", publishStart),
            ("published", publishedAt),
            ("subscribed", subscribedAt),
            ("frame", firstFrameAt),
        ])
        return frameFeeder
    } catch {
        frameFeeder.cancel()
        throw error
    }
}

/// Echoes a received payload back on the same topic, forming the far half of the data round trip.
private final class EchoBackDelegate: NSObject, RoomDelegate, @unchecked Sendable {
    private let room: Room
    private let topic: String

    init(room: Room, topic: String) {
        self.room = room
        self.topic = topic
        super.init()
    }

    func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType _: EncryptionType) {
        guard topic == self.topic else { return }
        Task { [room, topic] in
            try? await room.localParticipant.publish(data: data, options: DataPublishOptions(topic: topic))
        }
    }
}
