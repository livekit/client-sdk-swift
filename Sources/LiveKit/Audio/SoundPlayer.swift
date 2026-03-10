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

@preconcurrency import AVFAudio

public class SoundPlayer: Loggable, @unchecked Sendable {
    // MARK: - Public

    public static let shared = SoundPlayer()

    // MARK: - Private

    private let engine = AVAudioEngine()
    private let playerNodePool: AVAudioPlayerNodePool

    private struct State {
        var sounds: [String: AVAudioPCMBuffer] = [:]
        var activePlaybacks: [String: [SoundPlayback]] = [:]
    }

    private let _state = StateSync(State())

    init(poolSize: Int = 10) {
        playerNodePool = AVAudioPlayerNodePool(poolSize: poolSize)
        engine.attach(playerNodePool)
    }

    // MARK: - Engine lifecycle

    private var outputFormat: AVAudioFormat? {
        let format = engine.outputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return nil }
        return format
    }

    private func startIfNeeded() throws {
        guard !engine.isRunning else { return }
        guard let outputFormat else {
            throw LiveKitError(.audioEngine, message: "Invalid output format")
        }
        let playerNodeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: outputFormat.sampleRate,
                                             channels: outputFormat.channelCount,
                                             interleaved: outputFormat.isInterleaved)!
        engine.connect(playerNodePool, to: engine.mainMixerNode,
                       format: outputFormat, playerNodeFormat: playerNodeFormat)
        try engine.start()
    }

    // MARK: - Public API

    public func prepare(url: URL, withId id: String) throws {
        try startIfNeeded()

        guard let outputFormat else {
            throw LiveKitError(.audioEngine, message: "Failed to get output format")
        }

        // Prepare audio file
        let audioFile = try AVAudioFile(forReading: url)
        // Prepare buffer
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            throw LiveKitError(.audioEngine, message: "Failed to allocate audio buffer")
        }
        // Read all into buffer
        try audioFile.read(into: readBuffer, frameCount: AVAudioFrameCount(audioFile.length))
        // Compute required convert buffer capacity
        let outputBufferCapacity = AudioConverter.frameCapacity(from: readBuffer.format, to: outputFormat, inputFrameCount: readBuffer.frameLength)
        // Create converter
        guard let converter = AudioConverter(from: readBuffer.format, to: outputFormat, outputBufferCapacity: outputBufferCapacity) else {
            throw LiveKitError(.audioEngine, message: "Failed to create audio converter")
        }
        // Convert to suitable format for audio engine
        let convertedBuffer = converter.convert(from: readBuffer)
        // Register
        _state.mutate {
            $0.sounds[id] = convertedBuffer
        }
    }

    public func release(id: String) {
        // Stop active playbacks before removing
        let (playbacks, shouldStop) = _state.mutate {
            let playbacks = $0.activePlaybacks.removeValue(forKey: id) ?? []
            $0.sounds.removeValue(forKey: id)
            return (playbacks, $0.sounds.isEmpty)
        }

        for playback in playbacks {
            playback.stop()
        }

        if shouldStop {
            playerNodePool.stop()
            engine.stop()
        }
    }

    /// Stops all playing or queued sounds without releasing prepared audio buffers.
    public func stopAll() {
        playerNodePool.reset()
        _state.mutate { $0.activePlaybacks.removeAll() }
    }

    /// Stops all playing or queued sounds for the specified id without releasing prepared audio buffers.
    public func stop(id: String) {
        let playbacks = _state.mutate {
            $0.activePlaybacks.removeValue(forKey: id) ?? []
        }
        for playback in playbacks {
            playback.stop()
        }
    }

    public func play(id: String) throws {
        try startIfNeeded()

        guard let audioBuffer = _state.read(\.sounds[id]) else {
            throw LiveKitError(.audioEngine, message: "Sound not prepared")
        }

        guard let outputFormat else {
            throw LiveKitError(.audioEngine, message: "Failed to get output format")
        }

        // Convert if format doesn't match. A new converter is created each time
        // to avoid thread-safety issues with shared converter state.
        let bufferToSchedule: AVAudioPCMBuffer
        if audioBuffer.format != outputFormat {
            let outputBufferCapacity = AudioConverter.frameCapacity(from: audioBuffer.format,
                                                                    to: outputFormat,
                                                                    inputFrameCount: audioBuffer.frameLength)
            guard let converter = AudioConverter(from: audioBuffer.format,
                                                 to: outputFormat,
                                                 outputBufferCapacity: outputBufferCapacity)
            else {
                throw LiveKitError(.audioEngine, message: "Failed to create audio converter")
            }
            bufferToSchedule = converter.convert(from: audioBuffer)
        } else {
            bufferToSchedule = audioBuffer
        }

        let playback = try playerNodePool.play(bufferToSchedule)
        _state.mutate {
            // Clean up finished playbacks
            $0.activePlaybacks[id] = ($0.activePlaybacks[id] ?? []).filter { $0.isPlaying }
            $0.activePlaybacks[id, default: []].append(playback)
        }
    }
}
