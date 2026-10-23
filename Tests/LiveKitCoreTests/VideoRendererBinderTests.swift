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

import AVFoundation
import CoreVideo
import Foundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// The binder is what makes a burst of `VideoView.track` / `isEnabled` writes converge on the last
/// one. No view, no WebRTC: a recording fake stands in for the track. Nothing is polled except
/// the deinit path: a request enqueues its drain on the RTC executor's serial queue before it
/// returns, so a hop onto that executor afterwards is queued behind every drain requested so far.
@Suite(.tags(.concurrency), .bug("https://github.com/livekit/client-sdk-swift/issues/1139"))
struct VideoRendererBinderTests {
    /// Records renderer add/remove calls; the binder cannot tell it from a real track. State lives in
    /// a `StateSync` because the binder writes from the RTC executor while the test reads.
    private class FakeTrack: NSObject, VideoTrackProtocol, @unchecked Sendable {
        struct State {
            var renderers: [ObjectIdentifier] = []
            var adds = 0
            var removes = 0
            var peakRendererCount = 0
        }

        let state = StateSync(State())

        func add(videoRenderer: VideoRenderer) {
            state.mutate {
                $0.renderers.append(ObjectIdentifier(videoRenderer as AnyObject))
                $0.adds += 1
                $0.peakRendererCount = max($0.peakRendererCount, $0.renderers.count)
            }
        }

        func remove(videoRenderer: VideoRenderer) {
            let id = ObjectIdentifier(videoRenderer as AnyObject)
            state.mutate {
                $0.renderers.removeAll { $0 == id }
                $0.removes += 1
            }
        }

        func feeds(_ binder: VideoRendererBinder) -> Bool {
            state.read { $0.renderers.contains(ObjectIdentifier(binder.sink)) }
        }

        var rendererCount: Int { state.read { $0.renderers.count } }
        var peakRendererCount: Int { state.peakRendererCount }
        var adds: Int { state.adds }
        var removes: Int { state.removes }
    }

    /// A track whose attach blocks the RTC executor until released, so requests made meanwhile
    /// have to queue up in the binder rather than being applied one by one.
    private final class GatedTrack: FakeTrack, @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)

        override func add(videoRenderer: VideoRenderer) {
            super.add(videoRenderer: videoRenderer)
            _ = gate.wait(timeout: .now() + 5)
        }

        func release() {
            gate.signal()
        }
    }

    /// Records what reaches the sink's target, per optional callback.
    private final class FakeRenderer: NSObject, VideoRenderer, @unchecked Sendable {
        struct Counts: Equatable {
            var sizes = 0
            var frames = 0
            var framesWithCapture = 0
        }

        let counts = StateSync(Counts())
        @MainActor var isAdaptiveStreamEnabled: Bool { true }
        @MainActor var adaptiveStreamSize: CGSize { CGSize(width: 320, height: 180) }

        func set(size _: CGSize) {
            counts.mutate { $0.sizes += 1 }
        }

        func render(frame _: VideoFrame) {
            counts.mutate { $0.frames += 1 }
        }

        func render(frame _: VideoFrame, captureDevice _: AVCaptureDevice?, captureOptions _: VideoCaptureOptions?) {
            counts.mutate { $0.framesWithCapture += 1 }
        }
    }

    /// Returns once every request made so far has been applied or superseded.
    private static func settle() async {
        await RTC.run {}
    }

    @Test func lastRequestWins() async {
        let a = FakeTrack(), b = FakeTrack(), c = FakeTrack()
        let binder = VideoRendererBinder()

        for _ in 0 ..< 500 {
            binder.request(a)
            binder.request(b)
        }
        binder.request(c)
        await Self.settle()

        #expect(c.feeds(binder))
        #expect(a.rendererCount == 0)
        #expect(b.rendererCount == 0)
    }

    @Test func requestsMadeWhileTheExecutorIsBusyCollapseToTheLast() async throws {
        let gate = GatedTrack()
        let a = FakeTrack(), b = FakeTrack()
        let binder = VideoRendererBinder()

        binder.request(gate)
        try await poll(for: "drain blocked inside the gated attach") { gate.adds == 1 }
        for _ in 0 ..< 500 {
            binder.request(a)
            binder.request(b)
        }
        gate.release()
        await Self.settle()

        #expect(gate.removes == 1)
        #expect(a.adds == 0)
        #expect(b.adds == 1)
        #expect(b.feeds(binder))
    }

    @Test func repeatedRequestForTheSameTrackAttachesOnce() async {
        let a = FakeTrack()
        let binder = VideoRendererBinder()

        binder.request(a)
        await Self.settle()
        binder.request(a)
        binder.request(a)
        await Self.settle()
        #expect(a.adds == 1)

        binder.request(nil)
        await Self.settle()
        #expect(a.removes == 1)
        #expect(a.rendererCount == 0)
    }

    @Test func disableThenEnableEndsAttachedOnce() async {
        let a = FakeTrack()
        let binder = VideoRendererBinder()

        binder.request(a)
        await Self.settle()
        for _ in 0 ..< 50 {
            binder.request(nil)
            binder.request(a)
        }
        await Self.settle()

        #expect(a.feeds(binder))
        #expect(a.rendererCount == 1)
        #expect(a.peakRendererCount == 1)
    }

    /// Teardown runs on the release queue rather than the RTC executor, so this one is polled.
    @Test func droppingTheBinderDetaches() async throws {
        let a = FakeTrack()
        var binder: VideoRendererBinder? = VideoRendererBinder()

        binder?.request(a)
        await Self.settle()
        #expect(a.rendererCount == 1)

        binder = nil
        try await poll(for: "detached after deinit") { a.rendererCount == 0 }
    }

    /// Requests raced from many tasks have no defined last one, so the final request is made after
    /// they all return; the invariant holds throughout: no track is ever attached twice.
    @Test func concurrentRequestersNeverDoubleAttach() async {
        let tracks = (0 ..< 4).map { _ in FakeTrack() }
        let binder = VideoRendererBinder()

        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 8 {
                group.addTask {
                    for j in 0 ..< 200 {
                        binder.request((i + j) % 3 == 0 ? nil : tracks[(i + j) % tracks.count])
                    }
                }
            }
        }
        binder.request(tracks[0])
        await Self.settle()

        #expect(tracks[0].feeds(binder))
        #expect(tracks.map(\.rendererCount).reduce(0, +) == 1)
        #expect(tracks.allSatisfy { $0.peakRendererCount <= 1 })
    }

    /// Tracks invoke every optional `VideoRenderer` callback on whatever is registered, so the sink
    /// must forward each of them, not just the one `VideoView` itself implements.
    @Test func sinkForwardsEveryCallbackWhileItsTargetLives() throws {
        let sink = VideoRendererBinder.Sink()
        var target: FakeRenderer? = FakeRenderer()
        let frame = try Self.makeFrame()

        sink.target = target
        sink.set(size: CGSize(width: 64, height: 64))
        sink.render(frame: frame)
        sink.render(frame: frame, captureDevice: nil, captureOptions: nil)
        #expect(target?.counts.copy() == FakeRenderer.Counts(sizes: 1, frames: 1, framesWithCapture: 1))

        target = nil
        sink.render(frame: frame)
        sink.render(frame: frame, captureDevice: nil, captureOptions: nil)
        #expect(sink.target == nil)
    }

    private static func makeFrame() throws -> VideoFrame {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        return try VideoFrame(dimensions: Dimensions(width: 64, height: 64),
                              rotation: ._0,
                              timeStampNs: 0,
                              buffer: CVPixelVideoBuffer(pixelBuffer: #require(pixelBuffer)))
    }
}
