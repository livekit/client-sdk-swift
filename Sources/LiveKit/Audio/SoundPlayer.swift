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
    private let engine = AVAudioEngine()
    private let playerNodes = AVAudioPlayerNodePool()
    public let outputFormat: AVAudioFormat

    // Session requirement id for this object
    private let sessionRequirementId = UUID()

    private struct State {
        var sounds: [String: AVAudioPCMBuffer] = [:]
    }

    private let _state = StateSync(State())

    public init() {
        outputFormat = engine.outputNode.outputFormat(forBus: 0)
        playerNodes.attach(to: engine)
    }

    public func startEngine() async throws {
        guard !engine.isRunning else {
            log("Engine already running", .info)
            return
        }
        log("Starting audio engine...")

        playerNodes.connect(to: engine, node: engine.mainMixerNode, format: outputFormat)

        // Request
        #if os(iOS) || os(visionOS) || os(tvOS)
        AudioManager.shared.audioSession.set(requirement: .playbackOnly, for: sessionRequirementId)
        #endif

        try engine.start()
        log("Audio engine started")
    }

    public func stopEngine() {
        guard engine.isRunning else {
            log("Engine already stopped", .info)
            return
        }
        log("Stopping audio engine...")

        playerNodes.stop()
        engine.stop()

        #if os(iOS) || os(visionOS) || os(tvOS)
        AudioManager.shared.audioSession.set(requirement: .none, for: sessionRequirementId)
        #endif

        log("Audio engine stopped")
    }

    public func prepare(url: URL, withId id: String) throws {
        // Prepare audio file
        let audioFile = try AVAudioFile(forReading: url)
        // Prepare buffer
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate buffer"])
        }
        // Read all into buffer
        try audioFile.read(into: readBuffer, frameCount: AVAudioFrameCount(audioFile.length))
        // Compute required convert buffer capacity
        let outputBufferCapacity = AudioConverter.frameCapacity(from: readBuffer.format, to: outputFormat, inputFrameCount: readBuffer.frameLength)
        // Create converter
        guard let converter = AudioConverter(from: readBuffer.format, to: outputFormat, outputBufferCapacity: outputBufferCapacity) else {
            throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create converter"])
        }
        // Convert to suitable format for audio engine
        let convertedBuffer = converter.convert(from: readBuffer)
        // Register
        _state.mutate {
            $0.sounds[id] = convertedBuffer
        }
    }

    public func play(id: String) async throws {
        guard engine.isRunning else {
            throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Engine not running"])
        }
        guard let audioBuffer = _state.read(\.sounds[id]) else {
            throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Sound not prepared"])
        }
        try playerNodes.scheduleBuffer(audioBuffer)
    }
}

// Support scheduling buffer to play concurrently
class AVAudioPlayerNodePool: @unchecked Sendable, Loggable {
    let poolSize: Int
    private let mixerNode = AVAudioMixerNode()

    private struct State {
        var playerNodes: [AVAudioPlayerNode]
    }

    private let audioCallbackQueue = DispatchQueue(label: "audio.playerNodePool.queue")

    private let _state: StateSync<State>

    init(poolSize: Int = 10) {
        self.poolSize = poolSize
        let playerNodes = (0 ..< poolSize).map { _ in AVAudioPlayerNode() }
        _state = StateSync(State(playerNodes: playerNodes))
    }

    func attach(to engine: AVAudioEngine) {
        let playerNodes = _state.read(\.playerNodes)
        // Attach playerNodes
        for playerNode in playerNodes {
            engine.attach(playerNode)
        }
        // Attach mixerNode
        engine.attach(mixerNode)
    }

    func connect(to engine: AVAudioEngine, node: AVAudioNode, format: AVAudioFormat? = nil) {
        let playerNodes = _state.read(\.playerNodes)
        for playerNode in playerNodes {
            engine.connect(playerNode, to: mixerNode, format: format)
        }
        engine.connect(mixerNode, to: node, format: format)
    }

    func detach(from engine: AVAudioEngine) {
        let playerNodes = _state.read(\.playerNodes)
        // Detach playerNodes
        for playerNode in playerNodes {
            playerNode.stop()
            engine.detach(playerNode)
        }
        // Detach mixerNode
        engine.detach(mixerNode)
    }

    func scheduleBuffer(_ buffer: AVAudioPCMBuffer) throws {
        guard let node = nextAvailablePlayerNode() else {
            throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "No available player nodes"])
        }
        log("Next node: \(node)")

        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self, weak node] _ in
            guard let self else { return }
            audioCallbackQueue.async { [weak node] in
                guard let node else { return }
                node.stop() // Stop the node
            }
        }
        node.play()
    }

    // Stops all player nodes
    func stop() {
        for node in _state.read(\.playerNodes) {
            node.stop()
        }
    }

    private func nextAvailablePlayerNode() -> AVAudioPlayerNode? {
        // Find first available node
        guard let node = _state.read({ $0.playerNodes.first(where: { !$0.isPlaying }) }) else {
            return nil
        }

        // Ensure node settings
        node.volume = 1.0
        node.pan = 0.0

        return node
    }
}
