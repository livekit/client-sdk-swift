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
        var owner: VideoCapturer? = VideoCapturer(delegate: frames, mediaLogEmit: output.emit)
        weak var weakOwner = owner
        try runCapture(#require(owner), frames: frames, output: output)
        owner = nil
        #expect(weakOwner == nil)
        #expect(output.records.copy().count == 2)
        #expect(output.records.copy().last?.0.repeats == 19)
        #expect(output.records.copy().last?.1.contains("final=true") == true)
    }

    @Test func mixerLogsAfterEngineStopAndReleasesOwner() throws {
        let output = Output()
        var owner: MixerEngineObserver? = MixerEngineObserver(mediaLogEmit: output.emit)
        weak var weakOwner = owner
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
        let capturer = VideoCapturer(delegate: frames, mediaLogEmit: output.emit)
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
