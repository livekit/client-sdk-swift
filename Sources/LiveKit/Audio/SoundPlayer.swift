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

    private struct Sound {
        let buffer: AVAudioPCMBuffer
        let sessionRequirementId: UUID
        var local: [SoundPlayback] = []
        var remote: [SoundPlayback] = []

        mutating func cleanUp() {
            local.removeAll { !$0.isPlaying }
            remote.removeAll { !$0.isPlaying }
        }

        mutating func stopAll() {
            for p in local { p.stop() }
            for p in remote { p.stop() }
            local.removeAll()
            remote.removeAll()
        }
    }

    private struct State {
        var sounds: [String: Sound] = [:]
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
        // Already prepared, ignore.
        guard _state.read({ $0.sounds[id] }) == nil else { return }

        // Read audio file into raw PCM buffer.
        let audioFile = try AVAudioFile(forReading: url)
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                                frameCapacity: AVAudioFrameCount(audioFile.length))
        else {
            throw LiveKitError(.audioEngine, message: "Failed to allocate audio buffer")
        }
        try audioFile.read(into: readBuffer, frameCount: AVAudioFrameCount(audioFile.length))

        // Acquire session requirement before starting engine.
        let requirementId = UUID()
        #if os(iOS) || os(visionOS) || os(tvOS)
        try AudioManager.shared.audioSession.set(requirement: .playbackOnly, for: requirementId)
        #endif

        try startIfNeeded()

        _state.mutate {
            $0.sounds[id] = Sound(buffer: readBuffer, sessionRequirementId: requirementId)
        }
    }

    public func release(id: String) {
        let (sound, shouldStop) = _state.mutate {
            $0.sounds[id]?.stopAll()
            let sound = $0.sounds.removeValue(forKey: id)
            return (sound, $0.sounds.isEmpty)
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
        _state.mutate {
            for id in $0.sounds.keys {
                $0.sounds[id]?.stopAll()
            }
        }
    }

    /// Stops all playing or queued sounds for the specified id without releasing prepared audio buffers.
    public func stop(id: String) {
        _state.mutate {
            $0.sounds[id]?.stopAll()
        }
    }

    public func play(id: String, options: PlaybackOptions = PlaybackOptions()) throws {
        if options.mode == .replace {
            stop(id: id)
        }

        guard let buffer = _state.read({ $0.sounds[id]?.buffer }) else {
            throw LiveKitError(.audioEngine, message: "Sound not prepared")
        }

        let playLocal = options.destination == .local || options.destination == .localAndRemote
        let playRemote = options.destination == .remote || options.destination == .localAndRemote

        var localPlayback: SoundPlayback?
        var remotePlayback: SoundPlayback?

        if playLocal {
            try startIfNeeded()

            guard let outputFormat else {
                throw LiveKitError(.audioEngine, message: "Failed to get output format")
            }

            let bufferToSchedule = try convertBuffer(buffer, to: outputFormat)
            localPlayback = try playerNodePool.play(bufferToSchedule, loop: options.loop)
        }

        if playRemote {
            remotePlayback = AudioManager.shared.mixer.playSound(buffer, loop: options.loop)
        }

        if localPlayback != nil || remotePlayback != nil {
            _state.mutate {
                $0.sounds[id]?.cleanUp()
                if let localPlayback {
                    $0.sounds[id]?.local.append(localPlayback)
                }
                if let remotePlayback {
                    $0.sounds[id]?.remote.append(remotePlayback)
                }
            }
        }
    }
}
