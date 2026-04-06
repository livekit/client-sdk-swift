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

@globalActor
public actor SoundPlayerActor {
    public static let shared = SoundPlayerActor()

    private init() {}
}

/// Options for controlling sound playback behavior.
public struct PlaybackOptions: Sendable {
    /// How to handle existing playback of the same sound.
    public enum Mode: Sendable {
        /// Play concurrently with any existing playback of the same sound.
        case concurrent
        /// Stop any existing playback of the same sound before playing.
        ///
        /// Replacement is scoped by sound identifier, not by destination.
        /// Existing local and remote playback for the same `id` are both stopped
        /// before the new playback starts.
        case replace
    }

    /// Where the sound should be played.
    public enum Destination: Sendable {
        /// Play locally only (through device speakers).
        case local
        /// Play for remote participants only (through WebRTC).
        ///
        /// Remote playback is best-effort. If the WebRTC mixer input path is unavailable
        /// (for example, no active remote-routing path is connected), playback is skipped.
        case remote
        /// Play both locally and for remote participants.
        ///
        /// Remote playback is best-effort and may be skipped when the WebRTC mixer input path
        /// is unavailable.
        case localAndRemote

        var includesLocal: Bool {
            self == .local || self == .localAndRemote
        }

        var includesRemote: Bool {
            self == .remote || self == .localAndRemote
        }
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

/// High-level API for preparing and playing short sounds locally and over the room mixer.
///
/// ```swift
/// try await SoundPlayer.shared.prepare(fileURL: clickFileURL, withId: "click")
/// try await SoundPlayer.shared.play(id: "click")
/// await SoundPlayer.shared.release(id: "click")
/// ```
///
/// Prepared sounds must come from local file URLs and use a format readable by `AVAudioFile`
/// on the current platform.
///
/// The recommended lifecycle for reusable clips is:
/// 1. Prepare once with ``prepare(fileURL:withId:)``
/// 2. Play one or more times with ``play(id:options:)``
/// 3. Release with ``release(id:)`` when no longer needed
///
/// Preparing a sound acquires a playback session requirement and may start the local engine
/// early to reduce first-play latency.
///
/// Local playback uses a fixed internal player-node pool. If that pool is exhausted,
/// ``play(id:options:)`` throws instead of silently dropping local playback.
///
/// Remote playback is best-effort. It depends on the WebRTC mixer input path being available,
/// which typically requires the microphone to be published. Local playback can still succeed
/// even when remote playback is skipped.
@SoundPlayerActor
public final class SoundPlayer: Loggable {
    // MARK: - Public

    /// Shared sound player instance.
    public static let shared = SoundPlayer()

    // MARK: - Private

    private let engine = AVAudioEngine()
    private let playerNodePool: AVAudioPlayerNodePool
    private let notificationCenter: NotificationCenter
    private var engineConfigurationObserver: NSObjectProtocol?

    private struct Sound {
        let sourceBuffer: AVAudioPCMBuffer
        let sessionRequirementHandle: SessionRequirementHandle
        var cachedLocalBuffer: AVAudioPCMBuffer?
        var cachedLocalBufferFormat: AVAudioFormat?
        var local: [SoundPlayback] = []
        var remote: [SoundPlayback] = []

        private static func stop(_ playbacks: inout [SoundPlayback]) async {
            for playback in playbacks {
                await playback.stop()
            }
            playbacks.removeAll()
        }

        mutating func cleanUp() {
            local.removeAll { !$0.isPlaying }
            remote.removeAll { !$0.isPlaying }
        }

        mutating func stop(destination: PlaybackOptions.Destination) async {
            switch destination {
            case .local:
                await Self.stop(&local)
            case .remote:
                await Self.stop(&remote)
            case .localAndRemote:
                await Self.stop(&local)
                await Self.stop(&remote)
            }
        }

        mutating func localBuffer(for playerNodeFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
            if let cachedLocalBuffer, let cachedLocalBufferFormat, cachedLocalBufferFormat == playerNodeFormat {
                return cachedLocalBuffer
            }

            let localBuffer: AVAudioPCMBuffer
            if sourceBuffer.format == playerNodeFormat {
                localBuffer = sourceBuffer
            } else {
                let outputBufferCapacity = AudioConverter.frameCapacity(from: sourceBuffer.format,
                                                                        to: playerNodeFormat,
                                                                        inputFrameCount: sourceBuffer.frameLength)
                guard let converter = AudioConverter(from: sourceBuffer.format,
                                                     to: playerNodeFormat,
                                                     outputBufferCapacity: outputBufferCapacity)
                else {
                    throw LiveKitError(.audioEngine, message: "Failed to create audio converter")
                }
                localBuffer = converter.convert(from: sourceBuffer)
            }

            cachedLocalBuffer = localBuffer
            cachedLocalBufferFormat = playerNodeFormat
            return localBuffer
        }
    }

    private struct LocalEngineState {
        var connectedOutputFormat: AVAudioFormat?
        var playerNodeFormat: AVAudioFormat?
        var needsReconnect = false

        init(connectedOutputFormat: AVAudioFormat? = nil,
             playerNodeFormat: AVAudioFormat? = nil,
             needsReconnect: Bool = false)
        {
            self.connectedOutputFormat = connectedOutputFormat
            self.playerNodeFormat = playerNodeFormat
            self.needsReconnect = needsReconnect
        }
    }

    private var sounds: [String: Sound] = [:]
    private var localEngineState = LocalEngineState()

    init(poolSize: Int = 10, notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        playerNodePool = AVAudioPlayerNodePool(poolSize: poolSize)
        engine.attach(playerNodePool)
        engineConfigurationObserver = notificationCenter.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                    object: engine,
                                                                    queue: nil)
        { [weak self] _ in
            guard let self else { return }
            Task {
                await self.handleEngineConfigurationChange()
            }
        }
    }

    deinit {
        if let engineConfigurationObserver {
            notificationCenter.removeObserver(engineConfigurationObserver)
        }
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

    private func resetLocalEngineState(needsReconnect: Bool) {
        localEngineState = LocalEngineState(needsReconnect: needsReconnect)
    }

    private func invalidateCachedLocalBuffers() {
        for id in Array(sounds.keys) {
            guard var sound = sounds[id] else { continue }
            sound.cachedLocalBuffer = nil
            sound.cachedLocalBufferFormat = nil
            sound.local.removeAll()
            sounds[id] = sound
        }
    }

    private func invalidateLocalState() {
        resetLocalEngineState(needsReconnect: true)
        playerNodePool.reset()
        invalidateCachedLocalBuffers()
    }

    private func handleEngineConfigurationChange() {
        invalidateLocalState()
    }

    private func reconnectEngine(outputFormat: AVAudioFormat, playerNodeFormat: AVAudioFormat) throws {
        playerNodePool.stop()
        engine.stop()
        engine.disconnect(playerNodePool)
        playerNodePool.setMaximumFramesToRender(engine.outputNode.auAudioUnit.maximumFramesToRender)
        engine.connect(playerNodePool, to: engine.mainMixerNode,
                       format: outputFormat, playerNodeFormat: playerNodeFormat)
        try engine.start()
        localEngineState.connectedOutputFormat = outputFormat
        localEngineState.playerNodeFormat = playerNodeFormat
        localEngineState.needsReconnect = false
    }

    private func startIfNeeded() throws -> AVAudioFormat {
        guard let outputFormat else {
            throw LiveKitError(.audioEngine, message: "Invalid output format")
        }
        let playerNodeFormat = makePlayerNodeFormat(for: outputFormat)
        let needsReconnect = localEngineState.needsReconnect
            || !engine.isRunning
            || localEngineState.connectedOutputFormat != outputFormat
            || localEngineState.playerNodeFormat != playerNodeFormat

        if needsReconnect {
            try reconnectEngine(outputFormat: outputFormat, playerNodeFormat: playerNodeFormat)
        }

        return playerNodeFormat
    }

    private func stopEngine() {
        resetLocalEngineState(needsReconnect: false)
        playerNodePool.stop()
        engine.stop()
    }

    private nonisolated static func decodeBuffer(from fileURL: URL) async throws -> AVAudioPCMBuffer {
        guard fileURL.isFileURL else {
            throw LiveKitError(.invalidParameter, message: "Only file URLs are supported")
        }

        return try await Task.detached(priority: .userInitiated) {
            let audioFile = try AVAudioFile(forReading: fileURL)
            guard let readBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(audioFile.length))
            else {
                throw LiveKitError(.audioEngine, message: "Failed to allocate audio buffer")
            }
            try audioFile.read(into: readBuffer, frameCount: AVAudioFrameCount(audioFile.length))
            return readBuffer
        }.value
    }

    // MARK: - Public API

    /// Decodes and caches audio for the given identifier.
    ///
    /// Preparing a sound also acquires a playback session requirement and starts the
    /// local engine early to reduce first-play latency.
    ///
    /// - Note: Only local file URLs are supported.
    /// - Note: The file format must be readable by `AVAudioFile` on the current platform.
    /// - Note: Repeated playback of the same short clip should generally reuse a prepared sound
    ///   instead of decoding from disk each time.
    public func prepare(fileURL: URL, withId id: String) async throws {
        guard sounds[id] == nil else { return }

        let readBuffer = try await Self.decodeBuffer(from: fileURL)
        let sessionRequirementHandle = try AudioManager.shared.acquireSessionRequirement(.playbackOnly)

        do {
            guard sounds[id] == nil else {
                try? sessionRequirementHandle.release()
                return
            }

            _ = try startIfNeeded()
            sounds[id] = Sound(sourceBuffer: readBuffer, sessionRequirementHandle: sessionRequirementHandle)
        } catch {
            try? sessionRequirementHandle.release()
            throw error
        }
    }

    /// Releases a prepared sound, stops any active playback, and relinquishes its session requirement.
    ///
    /// Releasing the last prepared sound also stops the local playback engine owned by `SoundPlayer`.
    public func release(id: String) async {
        guard var sound = sounds.removeValue(forKey: id) else { return }
        await sound.stop(destination: .localAndRemote)
        if sounds.isEmpty {
            stopEngine()
        }

        try? sound.sessionRequirementHandle.release()
    }

    /// Returns `true` if a sound has been prepared for the given identifier.
    public func isPrepared(id: String) -> Bool {
        sounds[id] != nil
    }

    /// Returns `true` if the sound currently has active playback for the selected destination.
    public func isPlaying(id: String, destination: PlaybackOptions.Destination = .localAndRemote) -> Bool {
        guard let sound = sounds[id] else { return false }
        switch destination {
        case .local:
            return sound.local.contains(where: \.isPlaying)
        case .remote:
            return sound.remote.contains(where: \.isPlaying)
        case .localAndRemote:
            return sound.local.contains(where: \.isPlaying) || sound.remote.contains(where: \.isPlaying)
        }
    }

    /// Stops all playing or queued sounds without releasing prepared audio buffers.
    public func stopAll(destination: PlaybackOptions.Destination = .localAndRemote) async {
        for id in sounds.keys {
            if var sound = sounds[id] {
                await sound.stop(destination: destination)
                sounds[id] = sound
            }
        }
    }

    /// Stops all playing or queued sounds for the specified id without releasing prepared audio buffers.
    public func stop(id: String, destination: PlaybackOptions.Destination = .localAndRemote) async {
        guard var sound = sounds[id] else { return }
        await sound.stop(destination: destination)
        sounds[id] = sound
    }

    /// Plays a prepared sound.
    ///
    /// Remote playback is best-effort and is skipped when the WebRTC mixer input path
    /// is unavailable.
    ///
    /// When `options.mode` is `.replace`, any existing playback for the same `id`
    /// is stopped for both local and remote destinations before the new playback starts.
    ///
    /// When `options.destination` includes `.localAndRemote`, local playback may still succeed
    /// even if remote playback is skipped.
    ///
    /// - Throws: ``LiveKitError`` if the sound is not prepared, local playback setup fails,
    ///   or the local player-node pool is exhausted.
    public func play(id: String, options: PlaybackOptions = PlaybackOptions()) async throws {
        guard var sound = sounds[id] else {
            throw LiveKitError(.audioEngine, message: "Sound not prepared")
        }

        if options.mode == .replace {
            await sound.stop(destination: .localAndRemote)
        }

        sound.cleanUp()

        var localPlayback: SoundPlayback?
        var remotePlayback: SoundPlayback?

        if options.destination.includesLocal {
            let playerNodeFormat = try startIfNeeded()
            let bufferToSchedule = try sound.localBuffer(for: playerNodeFormat)
            localPlayback = try playerNodePool.play(bufferToSchedule, loop: options.loop)
        }

        if options.destination.includesRemote {
            remotePlayback = AudioManager.shared.mixer.playSound(sound.sourceBuffer, loop: options.loop)
        }

        if let localPlayback {
            sound.local.append(localPlayback)
        }

        if let remotePlayback {
            sound.remote.append(remotePlayback)
        }

        sounds[id] = sound
    }
}
