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
import Foundation
@testable import LiveKit
@preconcurrency import LiveKitWebRTC
import Testing

struct MediaProducerTests {
    private final class Output: Sendable {
        let records = StateSync<[(MediaLogSummary.Entry, String)]>([])
        func emit(_ entry: MediaLogSummary.Entry, _ body: String) {
            records.mutate { $0.append((entry, body)) }
        }
    }

    private final class Frames: NSObject, LKRTCVideoCapturerDelegate {
        let count = StateSync(0)
        func capturer(_: LKRTCVideoCapturer, didCapture _: LKRTCVideoFrame) {
            count.mutate { $0 += 1 }
        }
    }

    private final class UnknownBuffer: NSObject, LKRTCVideoFrameBuffer {
        let width: Int32 = 16
        let height: Int32 = 16
        override var description: String { "token=synthetic-fixture-secret\nraw_buffer_payload" }
        func toI420() -> any LKRTCI420BufferProtocol { LKRTCI420Buffer(width: width, height: height) }
    }

    @Test func captureConversionFailureHasOnlyOneCountedDiagnostic() throws {
        let output = Output()
        let frames = Frames()
        var owner: VideoCapturer? = VideoCapturer(delegate: frames, mediaLogEmit: { entry, body in output.emit(entry, body) })
        weak var weakOwner: VideoCapturer?
        weakOwner = owner
        try runCapture(#require(owner), frames: frames, output: output)
        owner = nil
        #expect(weakOwner == nil)
        #expect(output.records.copy().count == 2)
        #expect(output.records.copy().last?.0.repeats == 19)
        #expect(output.records.copy().last?.1.contains("final=true") == true)
    }

    @Test func mixerLogsAfterEngineStopAndReleasesOwner() throws {
        let output = Output()
        var owner: MixerEngineObserver? = MixerEngineObserver(mediaLogEmit: { entry, body in output.emit(entry, body) })
        weak var weakOwner: MixerEngineObserver?
        weakOwner = owner
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let engine = AVAudioEngine()
        _ = owner?.engineDidStop(engine, isPlayoutEnabled: false, isRecordingEnabled: false)
        for _ in 0 ..< 20 {
            owner?.capture(appAudio: buffer)
        }
        #expect(output.records.copy().count == 1)
        #expect(output.records.copy().first?.0.event == .converterUnavailable)
        #expect(output.records.copy().first?.1 == "dropping audio buffer: reason=converter_unavailable sample_rate_hz=48000.0 channel_count=1")
        #expect(output.records.copy().first?.0.event.level == .warning)
        owner?._state.mutate { $0.playerNodeFormat = format }
        for _ in 0 ..< 20 {
            owner?.capture(appAudio: buffer)
        }
        #expect(output.records.copy().count == 2)
        #expect(output.records.copy().last?.0.event.level == .debug)
        #expect(output.records.copy().last?.1 == "dropping audio buffer: reason=input_disconnected")
        #expect(owner?.appAudioNode.isPlaying == false)
        owner = nil
        #expect(weakOwner == nil)
        #expect(output.records.copy().count == 4)
        #expect(output.records.copy().suffix(2).allSatisfy { $0.0.repeats == 19 && $0.1.contains("final=true") })
    }

    @Test func invalidPixelInputsUseOnlyScalarDetails() throws {
        let output = Output()
        let frames = Frames()
        let native = LKRTCVideoCapturer(delegate: frames)
        let capturer = VideoCapturer(delegate: frames, mediaLogEmit: { entry, body in output.emit(entry, body) })
        var unsafeBuffer: CVPixelBuffer?
        var unsupportedBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 1, 1, kCVPixelFormatType_32BGRA, nil, &unsafeBuffer) == kCVReturnSuccess)
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_OneComponent8, nil, &unsupportedBuffer) == kCVReturnSuccess)
        let unsafeInput = try #require(unsafeBuffer)
        let unsupportedInput = try #require(unsupportedBuffer)
        for _ in 0 ..< 20 {
            capturer.capture(pixelBuffer: unsafeInput, capturer: native, options: BufferCaptureOptions())
            capturer.capture(pixelBuffer: unsupportedInput, capturer: native, options: BufferCaptureOptions())
        }
        let records = output.records.copy()
        #expect(records.map(\.1) == [
            "dropping video frame: reason=unsafe_dimensions width_px=1 height_px=1",
            "dropping video frame: reason=unsupported_pixel_format pixel_format=\(kCVPixelFormatType_OneComponent8)",
        ])
        #expect(records.allSatisfy { $0.0.event.level == .warning })
        #expect(frames.count.copy() == 0)
    }

    @Test func stopThenStartKeepsNewLifetimeActive() async throws {
        let output = Output()
        let capturer = VideoCapturer(delegate: Frames(), mediaLogEmit: { entry, body in output.emit(entry, body) })
        _ = try await capturer.startCapture()
        recordBusyFrames(capturer, count: 3)
        try await withPausedTransition({ _ = try await capturer.stopCapture() }) {
            #expect(capturer.captureState == .stopped)
            _ = try await capturer.startCapture()
            recordBusyFrames(capturer, count: 2)
            // The old lifetime's drain is paused; the new first record is already visible.
            #expect(output.records.copy().count == 2)
        }
        #expect(capturer.captureState == .started)
        recordBusyFrames(capturer, count: 1)
        _ = try await capturer.stopCapture()
        #expect(output.records.copy().map { $0.0.repeats } == [0, 0, 2, 2])
        #expect(output.records.copy().suffix(2).allSatisfy { $0.1.contains("final=true") })
        recordBusyFrames(capturer, count: 1)
        #expect(output.records.copy().count == 4)
        _ = try await capturer.startCapture()
        recordBusyFrames(capturer, count: 2)
        _ = try await capturer.stopCapture()
        #expect(output.records.copy().map { $0.0.repeats } == [0, 0, 2, 2, 0, 1])
    }

    @Test func startThenStopKeepsStoppedLifetimeSilent() async throws {
        let output = Output()
        let capturer = VideoCapturer(delegate: Frames(), mediaLogEmit: { entry, body in output.emit(entry, body) })
        // Establish a stopped lifetime; newly constructed buffer capturers may log before first start.
        _ = try await capturer.startCapture()
        _ = try await capturer.stopCapture()
        try await withPausedTransition({ _ = try await capturer.startCapture() }) {
            #expect(capturer.captureState == .started)
            recordBusyFrames(capturer, count: 2)
            _ = try await capturer.stopCapture()
        }
        #expect(capturer.captureState == .stopped)
        recordBusyFrames(capturer, count: 1)
        #expect(output.records.copy().map { $0.0.repeats } == [0, 1])
        _ = try await capturer.startCapture()
        recordBusyFrames(capturer, count: 2)
        _ = try await capturer.stopCapture()
        #expect(output.records.copy().map { $0.0.repeats } == [0, 1, 0, 1])
    }

    /// Drives the real busy-frame diagnostic without enqueueing media work.
    private func recordBusyFrames(_ capturer: VideoCapturer, count: Int) {
        let native = LKRTCVideoCapturer(delegate: Frames())
        let frame = LKRTCVideoFrame(buffer: LKRTCI420Buffer(width: 16, height: 16), rotation: ._0, timeStampNs: 1)
        capturer._state.mutate { $0.isFrameProcessingBusy = true }
        for _ in 0 ..< count {
            capturer.capture(frame: frame, capturer: native, options: BufferCaptureOptions())
        }
        capturer._state.mutate { $0.isFrameProcessingBusy = false }
    }

    /// Suspends one lifecycle call after its state commit; the other completes before it resumes.
    private func withPausedTransition(_ operation: @escaping @Sendable () async throws -> Void,
                                      whilePaused: () async throws -> Void) async throws
    {
        let arrived = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await VideoCapturer.$afterLifecycleTransition.withValue({
                    arrived.continuation.yield()
                    for await _ in release.stream {
                        break
                    }
                }, operation: operation)
            }
            defer {
                arrived.continuation.finish()
                release.continuation.finish()
            }
            for await _ in arrived.stream {
                break
            }
            try await whilePaused()
            release.continuation.finish()
            try await group.waitForAll()
        }
    }

    private func runCapture(_ capturer: VideoCapturer, frames: Frames, output: Output) {
        let native = LKRTCVideoCapturer(delegate: frames)
        let completed = DispatchSemaphore(value: 0)
        capturer._state.onDidMutate = { new, old in
            if old.isFrameProcessingBusy, !new.isFrameProcessingBusy { completed.signal() }
        }
        let frame = LKRTCVideoFrame(buffer: UnknownBuffer(), rotation: ._0, timeStampNs: 1)
        for _ in 0 ..< 20 {
            capturer.capture(frame: frame, capturer: native, options: BufferCaptureOptions())
            // Join the dedicated capture queue before submitting the next frame, without sleeps.
            #expect(completed.wait(timeout: .now() + 2) == .success)
        }
        capturer.processingQueue.sync {}
        #expect(frames.count.copy() == 0)
        #expect(output.records.copy().count == 1)
        #expect(output.records.copy().first?.0.event.level == .error)
        #expect(output.records.copy().first?.1 == "dropping video frame: reason=unsupported_buffer_type buffer_type=UnknownBuffer")
    }
}
