/*
 * Copyright 2025 LiveKit
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

import AVFAudio
import Foundation

@objc
public final class LocalAudioTrackRecorder: NSObject, AudioRenderer {
    public typealias Stream = AsyncStream<Data>

    @objc
    public let track: LocalAudioTrack
    @objc
    public let format: AVAudioCommonFormat
    @objc
    public let sampleRate: Int
    @objc
    public let channels: Int = 1
    @objc
    public let maxSize: Int

    private let state = StateSync<State>(State())
    private struct State {
        var continuation: Stream.Continuation?
    }

    @objc
    public init(track: LocalAudioTrack, format: AVAudioCommonFormat, sampleRate: Int, maxSize: Int = 0) {
        self.track = track
        self.format = format
        self.sampleRate = sampleRate
        self.maxSize = maxSize

        AudioManager.shared.initRecording()
    }

    public func start() -> Stream? {
        guard state.continuation == nil else { return nil }

        let buffer: Stream.Continuation.BufferingPolicy = maxSize > 0 ? .bufferingNewest(maxSize) : .unbounded
        let stream = Stream(bufferingPolicy: buffer) { continuation in
            self.state.mutate {
                $0.continuation = continuation
            }
        }

        track.add(audioRenderer: self)
        AudioManager.shared.startLocalRecording()
        state.continuation?.onTermination = { @Sendable (_: Stream.Continuation.Termination) in
            // TODO: parametrize?
//            AudioManager.shared.stopLocalRecording()
            self.track.remove(audioRenderer: self)
            self.state.mutate {
                $0.continuation = nil
            }
        }

        return stream
    }

    @objc
    public func stop() {
        state.continuation?.finish()
    }
}

// MARK: - AudioRenderer

public extension LocalAudioTrackRecorder {
    func render(pcmBuffer: AVAudioPCMBuffer) {
        if let data = pcmBuffer
            .resample(toSampleRate: Double(sampleRate))?
            .convert(toCommonFormat: format)?
            .toData()
        {
            state.continuation?.yield(data)
        }
    }
}

// MARK: - Objective-C compatibility

public extension LocalAudioTrackRecorder {
    @objc
    @available(*, deprecated, message: "Use for/await instead.")
    func start(maxSize _: Int = 0, onData: @escaping (Data) -> Void, onCompletion: @escaping () -> Void) {
        guard let stream = start() else { return }
        Task {
            for try await data in stream {
                onData(data)
            }
            onCompletion()
        }
    }
}
