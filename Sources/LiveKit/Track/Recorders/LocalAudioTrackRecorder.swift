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

    private let track: LocalAudioTrack
    private let format: AVAudioCommonFormat

    private var continuation: Stream.Continuation?

    @objc
    public init(track: LocalAudioTrack, format: AVAudioCommonFormat = .pcmFormatInt16) {
        self.track = track
        self.format = format

        AudioManager.shared.initRecording()
    }

    public func start(maxSize: Int = 0) -> Stream {
        let buffer: Stream.Continuation.BufferingPolicy = maxSize > 0 ? .bufferingNewest(maxSize) : .unbounded
        let stream = Stream(bufferingPolicy: buffer) { continuation in
            self.continuation = continuation
        }

        track.add(audioRenderer: self)
        AudioManager.shared.startLocalRecording()
        continuation?.onTermination = { @Sendable (_: Stream.Continuation.Termination) in
            AudioManager.shared.stopLocalRecording()
            self.track.remove(audioRenderer: self)
        }

        return stream
    }

    @objc
    public func stop() {
        continuation?.finish()
    }

    public func render(pcmBuffer: AVAudioPCMBuffer) {
        if let data = pcmBuffer
            .convert(toCommonFormat: format)?
            .toData()
        {
            continuation?.yield(data)
        }
    }
}

// MARK: - Objective-C compatibility

public extension LocalAudioTrackRecorder {
    @objc
    @available(*, deprecated, message: "Use for/await instead.")
    func start(maxSize: Int = 0, onData: @escaping (Data) -> Void, onCompletion: @escaping () -> Void) {
        Task {
            for try await data in start(maxSize: maxSize) {
                onData(data)
            }
            onCompletion()
        }
    }
}
