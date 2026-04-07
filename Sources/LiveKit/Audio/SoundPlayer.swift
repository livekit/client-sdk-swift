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

/// High-level API for preparing and playing short sounds locally and over the room mixer.
///
/// ```swift
/// let click = try await SoundPlayer.shared.prepare(fileURL: clickFileURL, named: "click")
/// try await click.play()
/// await click.release()
/// ```
///
/// Prepared sounds must come from local file URLs and use a format readable by `AVAudioFile`.
/// Recommended lifecycle: prepare once, play as needed, then release.
/// Preparing a sound acquires a playback session requirement and may start the local engine early.
/// Local playback uses a fixed internal player-node pool and throws if the pool is exhausted.
/// Remote playback is best-effort and typically requires the microphone to be published.
@SoundPlayerActor
public final class SoundPlayer: Loggable {
    // MARK: - Public

    /// Shared sound player instance.
    public static let shared = SoundPlayer()

    // MARK: - Private

    let engine = AVAudioEngine()
    let playerNodePool: AVAudioPlayerNodePool
    let notificationCenter: NotificationCenter
    var engineConfigurationObserver: NSObjectProtocol?

    var sounds: [UUID: PreparedSound] = [:]
    var soundIdsByName: [String: UUID] = [:]
    var localEngineState = LocalEngineState()

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

    /// Decodes and caches audio, returning a handle for playback and release.
    ///
    /// Preparing a sound also acquires a playback session requirement and starts the
    /// local engine early to reduce first-play latency.
    ///
    /// The returned ``SoundHandle`` is a lightweight value token. `SoundPlayer` owns the
    /// prepared sound until the handle is released with ``SoundHandle/release()``.
    ///
    /// If `name` is provided and another prepared sound already uses the same name,
    /// the previous sound is stopped, released, and replaced. Use ``sound(named:)`` to look up
    /// the current handle for a name.
    ///
    /// - Note: Only local file URLs are supported.
    /// - Note: The file format must be readable by `AVAudioFile` on the current platform.
    /// - Note: Repeated playback of the same short clip should generally reuse a prepared sound
    ///   instead of decoding from disk each time.
    @discardableResult
    public func prepare(fileURL: URL, named name: String? = nil) async throws -> SoundHandle {
        let readBuffer = try await Self.decodeBuffer(from: fileURL)
        let sessionRequirementHandle = try AudioManager.shared.acquireSessionRequirement(.playbackOnly)
        let soundId = UUID()
        let replacedSoundId = name.flatMap { soundIdsByName[$0] }

        do {
            try startEngineIfNeeded()
            sounds[soundId] = PreparedSound(name: name,
                                            sourceBuffer: readBuffer,
                                            sessionRequirementHandle: sessionRequirementHandle)
            if let name {
                soundIdsByName[name] = soundId
            }

            if let replacedSoundId {
                await releaseSound(id: replacedSoundId)
            }

            return SoundHandle(id: soundId)
        } catch {
            try? sessionRequirementHandle.release()
            throw error
        }
    }

    /// Returns the current handle for a prepared sound associated with `name`, if any.
    ///
    /// Names are optional aliases. Preparing another sound with the same name replaces the
    /// previous mapping, so this returns the latest prepared sound for that name.
    public func sound(named name: String) -> SoundHandle? {
        guard let soundId = soundIdsByName[name], sounds[soundId] != nil else { return nil }
        return SoundHandle(id: soundId)
    }

    /// Stops all playing or queued sounds without releasing prepared audio buffers.
    public func stopAll(destination: SoundPlaybackOptions.Destination = .localAndRemote) async {
        for sound in sounds.values {
            await sound.stop(destination: destination)
        }
    }
}

extension SoundPlayer {
    var outputFormat: AVAudioFormat? {
        let format = engine.outputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return nil }
        return format
    }

    func makePlayerNodeFormat(for outputFormat: AVAudioFormat) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: outputFormat.sampleRate,
                                         channels: outputFormat.channelCount,
                                         interleaved: outputFormat.isInterleaved)
        else {
            throw LiveKitError(.soundPlayer, message: "Failed to create player node format")
        }
        return format
    }

    func resetLocalEngineState(needsReconnect: Bool) {
        localEngineState = LocalEngineState(needsReconnect: needsReconnect)
    }

    func invalidateCachedLocalBuffers() {
        for sound in sounds.values {
            sound.cachedLocalBuffer = nil
            sound.cachedLocalBufferFormat = nil
            sound.local.removeAll()
        }
    }

    func invalidateLocalState() {
        resetLocalEngineState(needsReconnect: true)
        playerNodePool.reset()
        invalidateCachedLocalBuffers()
    }

    func handleEngineConfigurationChange() {
        invalidateLocalState()
    }

    func reconnectEngine(outputFormat: AVAudioFormat, playerNodeFormat: AVAudioFormat) throws {
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

    @discardableResult
    func startEngineIfNeeded() throws -> AVAudioFormat {
        guard let outputFormat else {
            throw LiveKitError(.soundPlayer, message: "Invalid output format")
        }
        let playerNodeFormat = try makePlayerNodeFormat(for: outputFormat)
        let needsReconnect = localEngineState.needsReconnect
            || !engine.isRunning
            || localEngineState.connectedOutputFormat != outputFormat
            || localEngineState.playerNodeFormat != playerNodeFormat

        if needsReconnect {
            try reconnectEngine(outputFormat: outputFormat, playerNodeFormat: playerNodeFormat)
        }

        return playerNodeFormat
    }

    func stopEngine() {
        resetLocalEngineState(needsReconnect: false)
        playerNodePool.stop()
        engine.stop()
    }

    func releaseSound(id soundId: UUID) async {
        guard let sound = sounds.removeValue(forKey: soundId) else { return }

        if let name = sound.name, soundIdsByName[name] == soundId {
            soundIdsByName.removeValue(forKey: name)
        }

        await sound.stop(destination: .localAndRemote)
        if sounds.isEmpty {
            stopEngine()
        }

        try? sound.sessionRequirementHandle.release()
    }

    func release(_ sound: SoundHandle) async {
        await releaseSound(id: sound.id)
    }

    func isPrepared(_ sound: SoundHandle) -> Bool {
        sounds[sound.id] != nil
    }

    func isPlaying(_ sound: SoundHandle, destination: SoundPlaybackOptions.Destination = .localAndRemote) -> Bool {
        guard let sound = sounds[sound.id] else { return false }
        switch destination {
        case .local:
            return sound.local.contains(where: \.isPlaying)
        case .remote:
            return sound.remote.contains(where: \.isPlaying)
        case .localAndRemote:
            return sound.local.contains(where: \.isPlaying) || sound.remote.contains(where: \.isPlaying)
        }
    }

    func stop(_ sound: SoundHandle, destination: SoundPlaybackOptions.Destination = .localAndRemote) async {
        guard let soundState = sounds[sound.id] else { return }
        await soundState.stop(destination: destination)
    }

    func play(_ sound: SoundHandle, options: SoundPlaybackOptions = SoundPlaybackOptions()) async throws {
        guard let soundState = sounds[sound.id] else {
            throw LiveKitError(.soundPlayer, message: "Sound not prepared")
        }

        if options.mode == .replace {
            await soundState.stop(destination: .localAndRemote)
            guard sounds[sound.id] != nil else {
                throw LiveKitError(.soundPlayer, message: "Sound not prepared")
            }
        }

        soundState.cleanUp()

        if options.destination.includesLocal {
            let playerNodeFormat = try startEngineIfNeeded()
            let bufferToSchedule = try soundState.localBuffer(for: playerNodeFormat)
            soundState.local.append(try playerNodePool.play(bufferToSchedule, loop: options.loop))
        }

        if options.destination.includesRemote {
            if let remotePlayback = AudioManager.shared.mixer.playSound(soundState.sourceBuffer, loop: options.loop) {
                soundState.remote.append(remotePlayback)
            }
        }
    }

    static func decodeBuffer(from fileURL: URL) async throws -> AVAudioPCMBuffer {
        guard fileURL.isFileURL else {
            throw LiveKitError(.invalidParameter, message: "Only file URLs are supported")
        }

        return try await Task.detached(priority: .userInitiated) {
            let audioFile = try AVAudioFile(forReading: fileURL)
            guard let readBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(audioFile.length))
            else {
                throw LiveKitError(.soundPlayer, message: "Failed to allocate audio buffer")
            }
            try audioFile.read(into: readBuffer, frameCount: AVAudioFrameCount(audioFile.length))
            return readBuffer
        }.value
    }
}
