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

// BM-JOIN: Late-joiner auto-subscribe — the one case single PC is expected to win.
//
// BM-SESSION measures a track published into an *established* session, which single PC loses:
// with the client as sole offerer the SFU cannot push an offer, so a new subscription costs
// `MediaSectionsRequirement` → client offer → server answer (1.5 RTT) where dual PC costs a
// server offer → client answer (0.5 RTT). No amount of preallocation removes that: the binding
// the client needs (`a=msid` / `mid_to_track_id`) can only be stamped on an answer.
//
// This benchmark measures the opposite arrangement: the room is already full when the joiner
// arrives, so the subscription can be settled by the JOIN exchange rather than by a later one.
// That is the case preallocating receive sections in the initial offer is meant to serve — the
// server can then bind existing publications in the very first answer, with no second exchange,
// and the joiner can decode because it authored the offer. Dual PC still needs the server's
// follow-up offer after JOIN either way.
//
// Metrics, all wall-clock milliseconds from the joiner's `connect()` call unless noted:
//   connect_ms                  `connect()` call to return.
//   first_subscribed_ms         → first `didSubscribeTrack`.
//   all_subscribed_ms           → the last of the room's tracks subscribed.
//   first_frame_ms              → first decoded frame at the joiner's renderer.
//   all_frames_ms               → every subscribed track has produced a frame. The headline:
//                                 the moment a joiner can actually see the room.
//   connected_to_first_frame_ms `connect()` return → first frame. The *unmasked* figure.
//
// Read the subscribe metrics and the frame metrics as separate answers; they do not agree, and
// the disagreement is the finding. Subscribing is signalling, and single PC settles it earlier
// because the binding rides the JOIN answer. Frames wait on DTLS either way, so measured on
// staging the earlier subscribe does not convert into an earlier frame — the two arms land
// within noise of each other end to end. Quote `first_frame_ms`, not the subscribe metrics,
// for anything user-facing: `first_subscribed_ms` also moves with *when* the SDK happens to
// fire its callback relative to `connect()` returning, which differs between SDKs.
//
// The publisher sweep is the second half of the question. Once the SDK preallocates a fixed
// number of receive sections, a room with more video publishers than that falls back to the
// `MediaSectionsRequirement` round trip for the remainder, so the sweep has to bracket whatever
// that number is: the default of 1 and 5 publishers straddles a preallocation of 3, making the
// cost of the overflow visible and the constant choosable from data rather than from taste.
// Override with `LK_BENCH_JOIN_PUBLISHERS=1,3,5`.
//
// Variants, per publisher count N:
//   BM-JOIN-DualPC-NPub
//   BM-JOIN-SinglePC-NPub

private let mConnect: BenchmarkMetric = .custom("connect_ms", polarity: .prefersSmaller, useScalingFactor: false)
private let mFirstSub: BenchmarkMetric = .custom("first_subscribed_ms", polarity: .prefersSmaller, useScalingFactor: false)
private let mAllSubs: BenchmarkMetric = .custom("all_subscribed_ms", polarity: .prefersSmaller, useScalingFactor: false)
private let mFirstFrame: BenchmarkMetric = .custom("first_frame_ms", polarity: .prefersSmaller, useScalingFactor: false)
private let mAllFrames: BenchmarkMetric = .custom("all_frames_ms", polarity: .prefersSmaller, useScalingFactor: false)
private let mConnectedToFrame: BenchmarkMetric = .custom("connected_to_first_frame_ms", polarity: .prefersSmaller, useScalingFactor: false)

/// 1 per iteration that never reached a milestone, 0 per iteration that completed — so a p90 of
/// 1 means at least a tenth of the runs failed. Without it a flaky arm looks identical to a
/// reliable one, only with fewer samples.
private let mFailed: BenchmarkMetric = .custom("failed_iterations", polarity: .prefersSmaller, useScalingFactor: false)

private let joinMetrics = [mConnect, mFirstSub, mAllSubs, mFirstFrame, mAllFrames, mConnectedToFrame, mFailed]

/// Publisher counts to sweep, from `LK_BENCH_JOIN_PUBLISHERS` (comma-separated).
///
/// Read at registration time, so the variants a run declares match the environment it runs in.
private func joinPublisherCounts() -> [Int] {
    let fallback = [1, 5]
    guard let raw = ProcessInfo.processInfo.environment["LK_BENCH_JOIN_PUBLISHERS"], !raw.isEmpty else { return fallback }
    let parsed = raw.split(separator: ",")
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        .filter { $0 > 0 }
    return parsed.isEmpty ? fallback : parsed
}

/// How long the seeded room is left publishing before the joiner arrives, from
/// `LK_BENCH_JOIN_SETTLE_MS`. See the call site for why this is not a token delay.
private func joinSettleMilliseconds() -> Int {
    let fallback = 2000
    guard let raw = ProcessInfo.processInfo.environment["LK_BENCH_JOIN_SETTLE_MS"],
          let parsed = Int(raw), parsed >= 0 else { return fallback }
    return parsed
}

let lateJoinerBenchmarks: @Sendable () -> Void = {
    for publisherCount in joinPublisherCounts() {
        for (mode, singlePC) in [("DualPC", false), ("SinglePC", true)] {
            Benchmark(
                "BM-JOIN-\(mode)-\(publisherCount)Pub",
                configuration: .init(
                    // As in BM-SESSION, wall clock for the whole iteration would include seeding
                    // the room, which no user waits for. The named milestones are the measurement.
                    metrics: joinMetrics,
                    timeUnits: .milliseconds,
                    units: Dictionary(uniqueKeysWithValues: joinMetrics.map { ($0, BenchmarkUnits.count) }),
                    warmupIterations: 2,
                    scalingFactor: .one,
                    // Each iteration seeds a fresh room with `publisherCount` publishers before it
                    // can measure anything, so the budget scales with the sweep.
                    maxDuration: .seconds(420 + 120 * publisherCount),
                    maxIterations: 15,
                ),
            ) { benchmark in
                let config = BenchmarkConfig.fromEnvironment()
                let tokenGen = TokenGenerator(apiKey: config.apiKey, apiSecret: config.apiSecret)

                for _ in benchmark.scaledIterations {
                    // As in BM-SESSION: an iteration contributes all of its samples or none.
                    let samples = MeasurementBuffer()
                    let failure = await runTolerantly {
                        try await runLateJoin(samples: samples,
                                              config: config,
                                              tokenGen: tokenGen,
                                              singlePC: singlePC,
                                              publisherCount: publisherCount)
                    }
                    if failure == nil { samples.commit(to: benchmark) }
                    reportFailure(failure, variant: "BM-JOIN-\(mode)-\(publisherCount)Pub")
                    benchmark.measurement(mFailed, failure == nil ? 0 : 1)
                    // Rooms are torn down; give the SFU a beat before the next room is seeded.
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }
}

/// The participants publishing into a seeded room, and the tasks feeding their tracks.
private struct SeededRoom {
    var publishers: [Room] = []
    var feeders: [Task<Void, Never>] = []

    func teardown() async {
        for feeder in feeders {
            feeder.cancel()
        }
        for publisher in publishers {
            await publisher.disconnect()
        }
    }
}

/// Fills a room with `publisherCount` participants each publishing one video track, and leaves it
/// publishing long enough to reach steady state.
///
/// Sequential so each publication is established before the next participant joins, and so a
/// failure is attributable to one of them.
private func seedRoom(named roomName: String,
                      publisherCount: Int,
                      roomOptions: RoomOptions,
                      config: BenchmarkConfig,
                      tokenGen: TokenGenerator) async throws -> SeededRoom
{
    var seeded = SeededRoom()
    do {
        for index in 0 ..< publisherCount {
            let publisher = Room(roomOptions: roomOptions)
            seeded.publishers.append(publisher)
            try await publisher.connect(url: config.url,
                                        token: tokenGen.generate(roomName: roomName, identity: "bench-pub-\(index)"))

            // Camera source: see the note in BM-SESSION — the default is screen share.
            let track = await LocalVideoTrack.createBufferTrack(name: "camera",
                                                                source: .camera,
                                                                options: BufferCaptureOptions())
            seeded.feeders.append(startFeedingFrames(into: track))
            try await publisher.localParticipant.publish(videoTrack: track)
        }

        // Not just so the publications are announced: a publisher that has only just started is
        // still ramping its encoder, and the first frame a joiner gets is then gated on the
        // publisher's first keyframe rather than on the join path. At a 500ms settle
        // `first_frame_ms` measured that warm-up — it read *higher* with one publisher than with
        // five, because seeding five takes longer and leaves the first of them further along. The
        // realistic arrangement is also the correct one here: the agent, or the first party to a
        // 1:1 call, has been publishing for seconds before anyone joins.
        try await Task.sleep(nanoseconds: UInt64(joinSettleMilliseconds()) * 1_000_000)
        return seeded
    } catch {
        await seeded.teardown()
        throw error
    }
}

/// Seeds a room with `publisherCount` publishing participants, then measures a joiner arriving
/// into it. Only the join is measured; the seeding is setup.
private func runLateJoin(samples: MeasurementBuffer,
                         config: BenchmarkConfig,
                         tokenGen: TokenGenerator,
                         singlePC: Bool,
                         publisherCount: Int) async throws
{
    let roomOptions = RoomOptions(singlePeerConnection: singlePC)
    let roomName = "benchmark-join-\(UUID().uuidString.prefix(8))"

    let seeded = try await seedRoom(named: roomName,
                                    publisherCount: publisherCount,
                                    roomOptions: roomOptions,
                                    config: config,
                                    tokenGen: tokenGen)

    // Spelled out rather than deferred because `defer` cannot await. A thrown milestone otherwise
    // leaves a roomful of live peer connections running for the rest of the benchmark, so every
    // later iteration measures on a progressively busier host.
    func teardown(joiner: Room?) async {
        if let joiner { await joiner.disconnect() }
        await seeded.teardown()
    }

    let observer = LateJoinObserver(expectedTracks: publisherCount)
    let joiner = Room(roomOptions: roomOptions)
    joiner.delegates.add(delegate: observer)
    // Keep the observer alive for the whole join; `delegates` holds it weakly.
    defer { _ = observer }

    do {
        let joinStart = nowMs()
        try await joiner.connect(url: config.url,
                                 token: tokenGen.generate(roomName: roomName, identity: "bench-joiner"))
        let connectedAt = nowMs()

        let firstSubscribedAt = try await observer.firstSubscribed.wait()
        let allSubscribedAt = try await observer.allSubscribed.wait()
        let firstFrameAt = try await observer.firstFrame.wait()
        let allFramesAt = try await observer.allFrames.wait()

        samples.record(mConnect, Int(connectedAt - joinStart))
        samples.record(mFirstSub, Int(firstSubscribedAt - joinStart))
        samples.record(mAllSubs, Int(allSubscribedAt - joinStart))
        samples.record(mFirstFrame, Int(firstFrameAt - joinStart))
        samples.record(mAllFrames, Int(allFramesAt - joinStart))
        // Media cannot flow before DTLS is up, so this is non-negative in practice; clamped
        // because the framework silently discards a negative sample, which would bias the
        // statistic rather than show the ordering surprise.
        samples.record(mConnectedToFrame, max(0, Int(firstFrameAt - connectedAt)))

        Timeline.mark("\(singlePC ? "SinglePC" : "DualPC")-\(publisherCount)Pub", [
            ("join", joinStart),
            ("connected", connectedAt),
            ("firstSub", firstSubscribedAt),
            ("allSubs", allSubscribedAt),
            ("firstFrame", firstFrameAt),
            ("allFrames", allFramesAt),
        ])
    } catch {
        await teardown(joiner: joiner)
        throw error
    }

    await teardown(joiner: joiner)
}
