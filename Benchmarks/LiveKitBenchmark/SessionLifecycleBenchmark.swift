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

private let sessionMetrics = [mConnect, mPeerVisible, mPubToSub, mFirstFrame, mPubToFrame, mDataRtt, mDisconnect]

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
                try await runSession(benchmark: benchmark,
                                     config: config,
                                     tokenGen: tokenGen,
                                     singlePC: singlePC)
                // Rooms are torn down; give the SFU a beat before the next identity joins.
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

/// One publisher/subscriber session, emitting every lifecycle metric from a single connection.
private func runSession(benchmark: Benchmark,
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

    // connect_ms — the publisher joins an empty room.
    let connectStart = nowMs()
    try await publisher.connect(url: config.url,
                                token: tokenGen.generate(roomName: roomName, identity: "bench-pub"))
    benchmark.measurement(mConnect, Int(nowMs() - connectStart))

    // peer_visible_ms — from the subscriber starting its connect to the publisher seeing it.
    let peerStart = nowMs()
    try await subscriber.connect(url: config.url,
                                 token: tokenGen.generate(roomName: roomName, identity: "bench-sub"))
    let visibleAt = try await peerVisible.visible.wait()
    benchmark.measurement(mPeerVisible, Int(visibleAt - peerStart))

    // pub_to_sub_ms / first_frame_ms / publish_to_first_frame_ms
    let track = await LocalVideoTrack.createBufferTrack(options: BufferCaptureOptions())
    let frameFeeder = startFeedingFrames(into: track)
    defer { frameFeeder.cancel() }

    let publishStart = nowMs()
    try await publisher.localParticipant.publish(videoTrack: track)
    let subscribedAt = try await subscriberObserver.subscribed.wait()
    let firstFrameAt = try await subscriberObserver.firstFrame.wait()

    benchmark.measurement(mPubToSub, Int(subscribedAt - publishStart))
    benchmark.measurement(mFirstFrame, Int(firstFrameAt - subscribedAt))
    benchmark.measurement(mPubToFrame, Int(firstFrameAt - publishStart))

    // data_rtt_ms — publisher → subscriber → publisher.
    let rttStart = nowMs()
    try await publisher.localParticipant.publish(data: Data("ping".utf8),
                                                 options: DataPublishOptions(topic: dataTopic))
    let echoedAt = try await dataEcho.received.wait()
    benchmark.measurement(mDataRtt, Int(echoedAt - rttStart))

    // disconnect_ms — publisher teardown only; the subscriber is closed outside the measurement.
    let disconnectStart = nowMs()
    await publisher.disconnect()
    benchmark.measurement(mDisconnect, Int(nowMs() - disconnectStart))

    await subscriber.disconnect()
}

/// Drives the buffer track at ~15fps until cancelled, so the subscriber has frames to render.
private func startFeedingFrames(into track: LocalVideoTrack) -> Task<Void, Never> {
    Task.detached {
        guard let capturer = track.capturer as? BufferCapturer else { return }
        while !Task.isCancelled {
            if let pixelBuffer = SyntheticVideo.makePixelBuffer() {
                capturer.capture(pixelBuffer)
            }
            try? await Task.sleep(nanoseconds: 66_000_000)
        }
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
