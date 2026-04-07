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

private struct PreparedSound {
    let name: String?
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
                throw LiveKitError(.soundPlayer, message: "Failed to create audio converter")
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

    private let engine = AVAudioEngine()
    private let playerNodePool: AVAudioPlayerNodePool
    private let notificationCenter: NotificationCenter
    private var engineConfigurationObserver: NSObjectProtocol?

    private var sounds: [UUID: PreparedSound] = [:]
    private var soundIdsByName: [String: UUID] = [:]
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

    // MARK: - Public API

    /// Decodes and caches audio, optionally associating it with a unique name.
    ///
    /// Preparing a sound also acquires a playback session requirement and starts the
    /// local engine early to reduce first-play latency.
    ///
    /// If `name` is provided and another prepared sound already uses the same name,
    /// the previous sound is stopped, released, and replaced.
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

    /// Returns the prepared sound currently associated with `name`, if any.
    public func sound(named name: String) -> SoundHandle? {
        guard let soundId = soundIdsByName[name], sounds[soundId] != nil else { return nil }
        return SoundHandle(id: soundId)
    }

    /// Releases a prepared sound, stops any active playback, and relinquishes its session requirement.
    ///
    /// Releasing the last prepared sound also stops the local playback engine owned by `SoundPlayer`.
    public func release(_ sound: SoundHandle) async {
        await releaseSound(id: sound.id)
    }

    /// Returns `true` if the handle still refers to a prepared sound.
    public func isPrepared(_ sound: SoundHandle) -> Bool {
        sounds[sound.id] != nil
    }

    /// Returns `true` if the sound currently has active playback for the selected destination.
    public func isPlaying(_ sound: SoundHandle, destination: PlaybackOptions.Destination = .localAndRemote) -> Bool {
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

    /// Stops all playing or queued sounds without releasing prepared audio buffers.
    public func stopAll(destination: PlaybackOptions.Destination = .localAndRemote) async {
        for soundId in Array(sounds.keys) {
            if var sound = sounds[soundId] {
                await sound.stop(destination: destination)
                if sounds[soundId] != nil { sounds[soundId] = sound }
            }
        }
    }

    /// Stops all playing or queued instances of a prepared sound without releasing its buffer.
    public func stop(_ sound: SoundHandle, destination: PlaybackOptions.Destination = .localAndRemote) async {
        guard var soundState = sounds[sound.id] else { return }
        await soundState.stop(destination: destination)
        if sounds[sound.id] != nil { sounds[sound.id] = soundState }
    }

    /// Stops all playing or queued sounds associated with the given name without releasing the prepared buffer.
    public func stop(named name: String, destination: PlaybackOptions.Destination = .localAndRemote) async {
        guard let sound = sound(named: name) else { return }
        await sound.stop(destination: destination)
    }

    /// Plays a prepared sound.
    ///
    /// Remote playback is best-effort and is skipped when the WebRTC mixer input path
    /// is unavailable.
    ///
    /// When `options.mode` is `.replace`, any existing playback for the same prepared sound
    /// is stopped for both local and remote destinations before the new playback starts.
    ///
    /// When `options.destination` includes `.localAndRemote`, local playback may still succeed
    /// even if remote playback is skipped.
    ///
    /// - Throws: ``LiveKitError`` if the sound is not prepared, local playback setup fails,
    ///   or the local player-node pool is exhausted.
    public func play(_ sound: SoundHandle, options: PlaybackOptions = PlaybackOptions()) async throws {
        guard var soundState = sounds[sound.id] else {
            throw LiveKitError(.soundPlayer, message: "Sound not prepared")
        }

        if options.mode == .replace {
            await soundState.stop(destination: .localAndRemote)
            guard sounds[sound.id] != nil else {
                throw LiveKitError(.soundPlayer, message: "Sound not prepared")
            }
        }

        soundState.cleanUp()

        var localPlayback: SoundPlayback?
        var remotePlayback: SoundPlayback?

        if options.destination.includesLocal {
            let playerNodeFormat = try startEngineIfNeeded()
            let bufferToSchedule = try soundState.localBuffer(for: playerNodeFormat)
            localPlayback = try playerNodePool.play(bufferToSchedule, loop: options.loop)
        }

        if options.destination.includesRemote {
            remotePlayback = AudioManager.shared.mixer.playSound(soundState.sourceBuffer, loop: options.loop)
        }

        if let localPlayback {
            soundState.local.append(localPlayback)
        }

        if let remotePlayback {
            soundState.remote.append(remotePlayback)
        }

        sounds[sound.id] = soundState
    }
}

private extension SoundPlayer {
    var outputFormat: AVAudioFormat? {
        let format = engine.outputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return nil }
        return format
    }

    func makePlayerNodeFormat(for outputFormat: AVAudioFormat) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: outputFormat.sampleRate,
                      channels: outputFormat.channelCount,
                      interleaved: outputFormat.isInterleaved)!
    }

    func resetLocalEngineState(needsReconnect: Bool) {
        localEngineState = LocalEngineState(needsReconnect: needsReconnect)
    }

    func invalidateCachedLocalBuffers() {
        for soundId in Array(sounds.keys) {
            guard var sound = sounds[soundId] else { continue }
            sound.cachedLocalBuffer = nil
            sound.cachedLocalBufferFormat = nil
            sound.local.removeAll()
            sounds[soundId] = sound
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

    func stopEngine() {
        resetLocalEngineState(needsReconnect: false)
        playerNodePool.stop()
        engine.stop()
    }

    func releaseSound(id soundId: UUID) async {
        guard var sound = sounds.removeValue(forKey: soundId) else { return }

        if let name = sound.name, soundIdsByName[name] == soundId {
            soundIdsByName.removeValue(forKey: name)
        }

        await sound.stop(destination: .localAndRemote)
        if sounds.isEmpty {
            stopEngine()
        }

        try? sound.sessionRequirementHandle.release()
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
