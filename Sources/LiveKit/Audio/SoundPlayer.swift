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

/// Options for controlling sound playback behavior.
public struct PlaybackOptions: Sendable {
    /// How to handle existing playback of the same sound.
    public enum Mode: Sendable {
        /// Play concurrently with any existing playback of the same sound.
        case concurrent
        /// Stop any existing playback of the same sound before playing.
        case replace
    }

    /// Where the sound should be played.
    public enum Destination: Sendable {
        /// Play locally only (through device speakers).
        case local
        /// Play for remote participants only (through WebRTC). Requires an active Room connection.
        case remote
        /// Play both locally and for remote participants.
        case localAndRemote
    }

    public var mode: Mode
    public var loop: Bool
    public var destination: Destination

    public init(mode: Mode = .concurrent, loop: Bool = false, destination: Destination = .localAndRemote) {
        self.mode = mode
        self.loop = loop
        self.destination = destination
    }
}

public class SoundPlayer: Loggable, @unchecked Sendable {
    // MARK: - Public

    public static let shared = SoundPlayer()

    // MARK: - Private

    private let engine = AVAudioEngine()
    private let playerNodePool: AVAudioPlayerNodePool
    private struct State {
        var sounds: [String: PreparedSound] = [:]
        var activePlaybacks: [String: [SoundPlayback]] = [:]
    }

    private struct PreparedSound {
        let buffer: AVAudioPCMBuffer
        let sessionRequirementId: UUID
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

    private func stopEngine() {
        playerNodePool.stop()
        engine.stop()
    }

    /// Converts a buffer to the target format. Returns the buffer as-is if formats already match.
    private func convertBuffer(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.format != targetFormat else { return buffer }
        let outputBufferCapacity = AudioConverter.frameCapacity(from: buffer.format,
                                                                to: targetFormat,
                                                                inputFrameCount: buffer.frameLength)
        guard let converter = AudioConverter(from: buffer.format,
                                             to: targetFormat,
                                             outputBufferCapacity: outputBufferCapacity)
        else {
            throw LiveKitError(.audioEngine, message: "Failed to create audio converter")
        }
        return converter.convert(from: buffer)
    }

    // MARK: - Public API

    public func prepare(url: URL, withId id: String) throws {
        // Prepare audio file
        let audioFile = try AVAudioFile(forReading: url)
        // Read into buffer using the file's processing format (always standard Float32 PCM)
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            throw LiveKitError(.audioEngine, message: "Failed to allocate audio buffer")
        }
        try audioFile.read(into: readBuffer, frameCount: AVAudioFrameCount(audioFile.length))

        let requirementId = UUID()
        #if os(iOS) || os(visionOS) || os(tvOS)
        try AudioManager.shared.audioSession.set(requirement: .playbackOnly, for: requirementId)
        #endif

        try startIfNeeded()

        _state.mutate {
            $0.sounds[id] = PreparedSound(buffer: readBuffer, sessionRequirementId: requirementId)
        }
    }

    public func release(id: String) {
        let (playbacks, sound, shouldStop) = _state.mutate {
            let playbacks = $0.activePlaybacks.removeValue(forKey: id) ?? []
            let sound = $0.sounds.removeValue(forKey: id)
            return (playbacks, sound, $0.sounds.isEmpty)
        }

        for playback in playbacks {
            playback.stop()
        }

        if shouldStop {
            stopEngine()
        }

        #if os(iOS) || os(visionOS) || os(tvOS)
        if let sound {
            try? AudioManager.shared.audioSession.set(requirement: .none, for: sound.sessionRequirementId)
        }
        #endif
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

    public func play(id: String, options: PlaybackOptions = PlaybackOptions()) throws {
        if options.mode == .replace {
            stop(id: id)
        }

        guard let audioBuffer = _state.read({ $0.sounds[id]?.buffer }) else {
            throw LiveKitError(.audioEngine, message: "Sound not prepared")
        }

        let playLocal = options.destination == .local || options.destination == .localAndRemote
        let playRemote = options.destination == .remote || options.destination == .localAndRemote

        // Play locally through standalone engine
        if playLocal {
            try startIfNeeded()

            guard let outputFormat else {
                throw LiveKitError(.audioEngine, message: "Failed to get output format")
            }

            let bufferToSchedule = try convertBuffer(audioBuffer, to: outputFormat)
            let playback = try playerNodePool.play(bufferToSchedule, loop: options.loop)
            _state.mutate {
                // Clean up finished playbacks
                $0.activePlaybacks[id] = ($0.activePlaybacks[id] ?? []).filter(\.isPlaying)
                $0.activePlaybacks[id, default: []].append(playback)
            }
        }

        // Play remotely through MixerEngineObserver's input path (WebRTC)
        if playRemote {
            if let playback = AudioManager.shared.mixer.playSound(audioBuffer, loop: options.loop) {
                _state.mutate {
                    $0.activePlaybacks[id] = ($0.activePlaybacks[id] ?? []).filter(\.isPlaying)
                    $0.activePlaybacks[id, default: []].append(playback)
                }
            }
        }
    }
}
