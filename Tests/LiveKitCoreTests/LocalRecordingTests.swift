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

@preconcurrency import AVFoundation
@testable import LiveKit
import LiveKitTestSupport
import Testing

@Suite(.serialized) struct LocalRecordingTests {
    @Test func manualRecordingDeliversAudioWithoutRoom() async throws {
        let manager = AudioManager.shared
        let observers = manager._state.engineObservers
        let processor = manager.capturePostProcessingDelegate
        let manualRendering = manager.isManualRenderingMode
        let probe = RecordingProbe()
        let source = try RecordingSineSource()
        let track = await LocalAudioTrack.createTrack()
        defer {
            do { try manager.stopLocalRecording() } catch { Issue.record(error) }
            track.remove(audioRenderer: probe)
            manager.capturePostProcessingDelegate = processor
            do { try manager.setManualRenderingMode(manualRendering) } catch { Issue.record(error) }
            manager.set(engineObservers: observers)
        }

        try manager.setManualRenderingMode(true)
        manager.set(engineObservers: [source])
        manager.capturePostProcessingDelegate = probe
        track.add(audioRenderer: probe)
        try manager.startLocalRecording()

        async let rendererCount = probe.rendererCount.wait(untilAtLeast: 1, timeout: 10)
        async let processorCount = probe.processorCount.wait(untilAtLeast: 1, timeout: 10)
        let counts = await (rendererCount, processorCount)
        print("Local recording: sourceFrames=\(source.frames.read { $0 }) rendererCallbacks=\(counts.0) delegateChunks=\(counts.1)")
        #expect(source.frames.read { $0 } > 0)
        #expect(counts.0 > 0, "LocalAudioTrack renderer must receive audio without a Room")
        #expect(counts.1 > 0, "Capture post-processing must receive audio without a Room")
    }
}

private final class RecordingProbe: NSObject, AudioRenderer, AudioCustomProcessingDelegate, Sendable {
    let rendererCount = ConcurrentCounter()
    let processorCount = ConcurrentCounter()
    var audioProcessingName: String { "RecordingProbe" }

    func render(pcmBuffer _: AVAudioPCMBuffer) {
        Task { await rendererCount.increment() }
    }

    func audioProcessingInitialize(sampleRate _: Int, channels _: Int) {}
    func audioProcessingRelease() {}
    func audioProcessingProcess(audioBuffer _: LKAudioBuffer) {
        Task { await processorCount.increment() }
    }
}

// AVAudioEngine owns and serializes node rendering; observer links use StateSync.
private final class RecordingSineSource: AudioEngineObserver, @unchecked Sendable {
    private let nextObserver = StateSync<(any AudioEngineObserver)?>(nil)
    var next: (any AudioEngineObserver)? {
        get { nextObserver.read { $0 } }
        set { nextObserver.mutate { $0 = newValue } }
    }

    let frames = StateSync(0)
    private let node: AVAudioSourceNode

    init() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let frames = frames
        var phase: Float = 0
        node = AVAudioSourceNode(format: format) { _, _, frameCount, buffers in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0 ..< Int(frameCount) {
                    samples[frame] = sin(phase) * 0.5
                    phase += 2 * .pi * 440 / 48000
                    if phase >= 2 * .pi { phase -= 2 * .pi }
                }
            }
            frames.mutate { $0 += Int(frameCount) }
            return noErr
        }
    }

    func engineDidCreate(_ engine: AVAudioEngine) -> Int {
        engine.attach(node)
        return 0
    }

    func engineWillConnectInput(_ engine: AVAudioEngine, src _: AVAudioNode?, dst: AVAudioNode,
                                format: AVAudioFormat, context _: [AnyHashable: Any]) -> Int
    {
        engine.connect(node, to: dst, format: format)
        return 0
    }

    func engineWillRelease(_ engine: AVAudioEngine) -> Int {
        engine.detach(node)
        return 0
    }
}
