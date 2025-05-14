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

/// A class that captures audio from a local track and streams it as a data stream
/// in a selected format that can be sent to other participants via ``ByteStreamWriter``.
@objc
public final class LocalAudioTrackRecorder: NSObject, Sendable, AudioRenderer {
    public typealias Stream = AsyncStream<Data>

    /// The local audio track to capture audio from.
    @objc
    public let track: LocalAudioTrack

    /// The format of the audio data to stream.
    @objc
    public let format: AVAudioCommonFormat

    /// The sample rate of the audio data to stream.
    @objc
    public let sampleRate: Int

    /// The number of channels of the audio data to stream.
    @objc
    public let channels: Int = 1

    /// The maximum size of the audio data to buffer.
    @objc
    public let maxSize: Int

    var isRecording: Bool {
        state.continuation != nil
    }

    private let state = StateSync<State>(State())
    private struct State {
        var continuation: Stream.Continuation?
    }

    /// Initialize the audio recorder with a local audio track.
    /// - Parameters:
    ///   - track: The local audio track to capture audio from.
    ///   - format: The format of the audio data to stream.
    ///   - sampleRate: The sample rate of the audio data to stream.
    ///   - maxSize: The maximum size of the audio data to buffer.
    /// - Note: The default maximum size is 0, which means that the audio data will be buffered indefinitely.
    @objc
    public init(track: LocalAudioTrack, format: AVAudioCommonFormat, sampleRate: Int, maxSize: Int = 0) {
        self.track = track
        self.format = format
        self.sampleRate = sampleRate
        self.maxSize = maxSize
    }

    /// Starts capturing audio from the local track and returns a stream of audio data.
    /// - Returns: A stream of audio data.
    /// - Throws: An error if the audio track cannot be started.
    public func start() async throws -> Stream {
        stop()

        try await track.startCapture()
        track.add(audioRenderer: self)

        let buffer: Stream.Continuation.BufferingPolicy = maxSize > 0 ? .bufferingNewest(maxSize) : .unbounded
        let stream = Stream(bufferingPolicy: buffer) { continuation in
            self.state.mutate {
                $0.continuation = continuation
            }
        }

        state.continuation?.onTermination = { @Sendable (_: Stream.Continuation.Termination) in
            self.track.remove(audioRenderer: self)
            self.state.mutate {
                $0.continuation = nil
            }
        }

        return stream
    }

    /// Stops capturing audio from the local track.
    @objc
    public func stop() {
        state.continuation?.finish()
    }

    func duration(_ dataSize: Int) -> TimeInterval {
        let totalSamples = dataSize / format.bytesPerSample
        let samplesPerChannel = totalSamples / channels
        return Double(samplesPerChannel) / Double(sampleRate)
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
        } else {
            assertionFailure("Failed to convert PCM buffer to data")
        }
    }
}

// MARK: - Objective-C compatibility

public extension LocalAudioTrackRecorder {
    /// Starts capturing audio from the local track and calls the provided closure with the audio data.
    /// - Parameters:
    ///   - maxSize: The maximum size of the audio data to buffer.
    ///   - onData: A closure that is called with the audio data.
    ///   - onCompletion: A closure that is called when the audio recording is completed.
    @objc
    @available(*, deprecated, message: "Use for/await instead.")
    func start(maxSize _: Int = 0, onData: @Sendable @escaping (Data) -> Void, onCompletion: @Sendable @escaping (Error?) -> Void) {
        Task {
            do {
                let stream = try await start()
                for try await data in stream {
                    onData(data)
                }
                onCompletion(nil)
            } catch {
                onCompletion(error)
            }
        }
    }
}
