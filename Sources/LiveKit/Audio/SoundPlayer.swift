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
        /// Play for remote participants only (through WebRTC).
        ///
        /// If remote routing is unavailable, playback is skipped.
        case remote
        /// Play both locally and for remote participants.
        ///
        /// Remote playback is best-effort and may be skipped if remote routing is unavailable.
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

        mutating func stop(destination: PlaybackOptions.Destination) {
            switch destination {
            case .local:
                for p in local {
                    p.stop()
                }
                local.removeAll()
            case .remote:
                for p in remote {
                    p.stop()
                }
                remote.removeAll()
            case .localAndRemote:
                for p in local {
                    p.stop()
                }
                for p in remote {
                    p.stop()
                }
                local.removeAll()
                remote.removeAll()
            }
        }
    }

    private struct State {
        var sounds: [String: Sound] = [:]
        var playerNodeFormat: AVAudioFormat?
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

    private func makePlayerNodeFormat(for outputFormat: AVAudioFormat) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: outputFormat.sampleRate,
                      channels: outputFormat.channelCount,
                      interleaved: outputFormat.isInterleaved)!
    }

    private func startIfNeeded(state: inout State) throws -> AVAudioFormat {
        if engine.isRunning, let playerNodeFormat = state.playerNodeFormat {
            return playerNodeFormat
        }
        guard let outputFormat else {
            throw LiveKitError(.audioEngine, message: "Invalid output format")
        }
        playerNodePool.setMaximumFramesToRender(engine.outputNode.auAudioUnit.maximumFramesToRender)
        let playerNodeFormat = makePlayerNodeFormat(for: outputFormat)
        engine.connect(playerNodePool, to: engine.mainMixerNode,
                       format: outputFormat, playerNodeFormat: playerNodeFormat)
        try engine.start()
        state.playerNodeFormat = playerNodeFormat
        return playerNodeFormat
    }

    private func stopEngine(state: inout State) {
        state.playerNodeFormat = nil
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

    /// Decodes and caches audio for the given identifier.
    ///
    /// Preparing a sound also acquires a playback session requirement and starts the
    /// local engine early to reduce first-play latency.
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

        do {
            let wasAlreadyPrepared = try _state.mutate { state in
                guard state.sounds[id] == nil else { return true }
                _ = try startIfNeeded(state: &state)
                state.sounds[id] = Sound(buffer: readBuffer, sessionRequirementId: requirementId)
                return false
            }

            guard !wasAlreadyPrepared else {
                #if os(iOS) || os(visionOS) || os(tvOS)
                try? AudioManager.shared.audioSession.removeRequirement(for: requirementId)
                #endif
                return
            }
        } catch {
            #if os(iOS) || os(visionOS) || os(tvOS)
            try? AudioManager.shared.audioSession.removeRequirement(for: requirementId)
            #endif
            throw error
        }
    }

    /// Releases a prepared sound, stops any active playback, and relinquishes its session requirement.
    public func release(id: String) {
        let sound = _state.mutate { state -> Sound? in
            guard var sound = state.sounds.removeValue(forKey: id) else { return nil }
            sound.stop(destination: .localAndRemote)
            if state.sounds.isEmpty {
                stopEngine(state: &state)
            }
            return sound
        }

        #if os(iOS) || os(visionOS) || os(tvOS)
        if let sound {
            try? AudioManager.shared.audioSession.removeRequirement(for: sound.sessionRequirementId)
        }
        #endif
    }

    /// Returns `true` if a sound has been prepared for the given identifier.
    public func isPrepared(id: String) -> Bool {
        _state.read { $0.sounds[id] != nil }
    }

    /// Returns `true` if the sound currently has active playback for the selected destination.
    public func isPlaying(id: String, destination: PlaybackOptions.Destination = .localAndRemote) -> Bool {
        _state.read { state in
            guard let sound = state.sounds[id] else { return false }
            switch destination {
            case .local:
                return sound.local.contains(where: \.isPlaying)
            case .remote:
                return sound.remote.contains(where: \.isPlaying)
            case .localAndRemote:
                return sound.local.contains(where: \.isPlaying) || sound.remote.contains(where: \.isPlaying)
            }
        }
    }

    /// Stops all playing or queued sounds without releasing prepared audio buffers.
    public func stopAll(destination: PlaybackOptions.Destination = .localAndRemote) {
        _state.mutate { state in
            for id in state.sounds.keys {
                state.sounds[id]?.stop(destination: destination)
            }
        }
    }

    /// Stops all playing or queued sounds for the specified id without releasing prepared audio buffers.
    public func stop(id: String, destination: PlaybackOptions.Destination = .localAndRemote) {
        _state.mutate { state in
            state.sounds[id]?.stop(destination: destination)
        }
    }

    /// Plays a prepared sound.
    ///
    /// Remote playback is best-effort and is skipped if remote routing is unavailable.
    ///
    /// - Throws: ``LiveKitError`` if the sound is not prepared or local playback setup fails.
    public func play(id: String, options: PlaybackOptions = PlaybackOptions()) throws {
        let playLocal = options.destination == .local || options.destination == .localAndRemote
        let playRemote = options.destination == .remote || options.destination == .localAndRemote

        try _state.mutate { state in
            guard var sound = state.sounds[id] else {
                throw LiveKitError(.audioEngine, message: "Sound not prepared")
            }

            if options.mode == .replace {
                sound.stop(destination: .localAndRemote)
            }

            sound.cleanUp()

            var localPlayback: SoundPlayback?
            var remotePlayback: SoundPlayback?

            if playLocal {
                let playerNodeFormat = try startIfNeeded(state: &state)
                let bufferToSchedule = try convertBuffer(sound.buffer, to: playerNodeFormat)
                localPlayback = try playerNodePool.play(bufferToSchedule, loop: options.loop)
            }

            if playRemote {
                remotePlayback = AudioManager.shared.mixer.playSound(sound.buffer, loop: options.loop)
            }

            if let localPlayback {
                sound.local.append(localPlayback)
            }

            if let remotePlayback {
                sound.remote.append(remotePlayback)
            }

            state.sounds[id] = sound
        }
    }
}
