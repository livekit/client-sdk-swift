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

@preconcurrency import AVFoundation

internal import LiveKitWebRTC

public final class MixerEngineObserver: Loggable {
    /// Adjust the output volume of all audio tracks. Range is 0.0 ~ 1.0.
    public var outputVolume: Float {
        get { _state.read { $0.outputVolume } }
        set {
            _state.mutate {
                $0.mainMixerNode?.outputVolume = newValue
                $0.outputVolume = newValue
            }
        }
    }

    /// Adjust the volume of captured app audio. Range is 0.0 ~ 1.0.
    public var appVolume: Float {
        get { _state.read { $0.appMixerNode.outputVolume } }
        set { _state.mutate { $0.appMixerNode.outputVolume = newValue } }
    }

    /// Adjust the volume of microphone audio. Range is 0.0 ~ 1.0.
    public var micVolume: Float {
        get { _state.read { $0.micMixerNode.outputVolume } }
        set { _state.mutate { $0.micMixerNode.outputVolume = newValue } }
    }

    /// Adjust the volume of microphone audio. Range is 0.0 ~ 1.0.
    public var soundPlayerVolume: Float {
        get { _state.read { $0.soundPlayerNodes.mixerNode.outputVolume } }
        set { _state.mutate { $0.soundPlayerNodes.mixerNode.outputVolume = newValue } }
    }

    // MARK: - Internal

    var appAudioNode: AVAudioPlayerNode {
        _state.read { $0.appNode }
    }

    var micAudioNode: AVAudioPlayerNode {
        _state.read { $0.micNode }
    }

    var soundPlayerNodes: AVAudioPlayerNodePool {
        _state.read { $0.soundPlayerNodes }
    }

    struct State {
        var next: (any AudioEngineObserver)?

        // App audio (Input)
        let appNode = AVAudioPlayerNode()
        let appMixerNode = AVAudioMixerNode()

        // Mic audio (Input), not connected for device rendering mode.
        let micNode = AVAudioPlayerNode()
        let micMixerNode = AVAudioMixerNode()

        // Sound player audio (Output)
        let soundPlayerNodes = AVAudioPlayerNodePool()

        // Reference to mainMixerNode
        weak var mainMixerNode: AVAudioMixerNode?
        var outputVolume: Float = 1.0

        // Internal states
        var isInputConnected: Bool = false

        // Cached converters
        var converters: [AVAudioFormat: AudioConverter] = [:]

        // Reference to engine format
        var playerNodeFormat: AVAudioFormat?
    }

    let _state = StateSync(State())

    public init() {}

    public func engineDidCreate(_ engine: AVAudioEngine) -> Int {
        log("isManualRenderingMode: \(engine.isInManualRenderingMode)")
        let (appNode, appMixerNode, micNode, micMixerNode, soundPlayerNodes) = _state.read {
            ($0.appNode, $0.appMixerNode, $0.micNode, $0.micMixerNode, $0.soundPlayerNodes)
        }

        engine.attach(appNode)
        engine.attach(appMixerNode)
        engine.attach(micNode)
        engine.attach(micMixerNode)
        engine.attach(soundPlayerNodes)

        // Invoke next
        return next?.engineDidCreate(engine) ?? 0
    }

    public func engineWillRelease(_ engine: AVAudioEngine) -> Int {
        log("isManualRenderingMode: \(engine.isInManualRenderingMode)")
        // Invoke next
        let nextResult = next?.engineWillRelease(engine)

        let (appNode, appMixerNode, micNode, micMixerNode, soundPlayerNodes) = _state.read {
            ($0.appNode, $0.appMixerNode, $0.micNode, $0.micMixerNode, $0.soundPlayerNodes)
        }

        engine.detach(appNode)
        engine.detach(appMixerNode)
        engine.detach(micNode)
        engine.detach(micMixerNode)
        engine.detach(soundPlayerNodes)

        return nextResult ?? 0
    }

    public func engineWillConnectInput(_ engine: AVAudioEngine, src: AVAudioNode?, dst: AVAudioNode, format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        log("isManualRenderingMode: \(engine.isInManualRenderingMode)")
        // Get the main input mixer node, for manual rendering mode this is currently the mainMixerNode
        let mainMixerNode = engine.isInManualRenderingMode ? engine.mainMixerNode : (context[kLKRTCAudioEngineInputMixerNodeKey] as? AVAudioMixerNode)

        guard let mainMixerNode else {
            // If failed to get main mixer, call next and return.
            return next?.engineWillConnectInput(engine, src: src, dst: dst, format: format, context: context) ?? 0
        }

        // Read nodes from state lock.
        let (appNode, appMixerNode, micNode, micMixerNode) = _state.read {
            ($0.appNode, $0.appMixerNode, $0.micNode, $0.micMixerNode)
        }

        // AVAudioPlayerNode doesn't support Int16 so we ensure to use Float32
        let playerNodeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: format.sampleRate,
                                             channels: format.channelCount,
                                             interleaved: format.isInterleaved)!

        log("Connecting app -> appMixer -> mainMixer")
        // appAudio -> appAudioMixer -> mainMixer
        engine.connect(appNode, to: appMixerNode, format: playerNodeFormat)
        engine.connect(appMixerNode, to: mainMixerNode, format: format)

        // src is not null if device rendering mode.
        if let src {
            log("Connecting src (device) to micMixer -> mainMixer")
            // mic (device) -> micMixer -> mainMixer
            engine.connect(src, to: micMixerNode, format: format)
        }

        log("Connecting micAudio (player) to micMixer -> mainMixer")
        // mic (player) -> micMixer -> mainMixer
        engine.connect(micNode, to: micMixerNode, format: playerNodeFormat)
        // Always connect micMixer to mainMixer
        engine.connect(micMixerNode, to: mainMixerNode, format: format)

        _state.mutate {
            if let previousEngineFormat = $0.playerNodeFormat, previousEngineFormat != format {
                // Clear cached converters when engine format changes
                $0.converters.removeAll()
            }
            $0.playerNodeFormat = playerNodeFormat
            $0.isInputConnected = true
        }

        // Invoke next
        return next?.engineWillConnectInput(engine, src: src, dst: dst, format: format, context: context) ?? 0
    }

    public func engineWillConnectOutput(_ engine: AVAudioEngine, src: AVAudioNode, dst: AVAudioNode?, format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        log("isManualRenderingMode: \(engine.isInManualRenderingMode)")
        // Get the main mixer
        let (outputVolume, soundPlayerNodes) = _state.mutate {
            $0.mainMixerNode = engine.mainMixerNode
            return ($0.outputVolume, $0.soundPlayerNodes)
        }

        engine.connect(soundPlayerNodes, to: engine.mainMixerNode, format: format)

        engine.mainMixerNode.outputVolume = outputVolume

        return next?.engineWillConnectOutput(engine, src: src, dst: dst, format: format, context: context) ?? 0
    }
}

// MARK: - AudioEngineObserver

extension MixerEngineObserver: AudioEngineObserver {
    public var next: (any AudioEngineObserver)? {
        get { _state.next }
        set { _state.mutate { $0.next = newValue } }
    }

    public func setNext(_ handler: any AudioEngineObserver) {
        next = handler
    }
}

extension MixerEngineObserver {
    // Create or use cached AudioConverter.
    func converter(for format: AVAudioFormat) -> AudioConverter? {
        _state.mutate {
            guard let playerNodeFormat = $0.playerNodeFormat else { return nil }

            if let converter = $0.converters[format] {
                return converter
            }

            let newConverter = AudioConverter(from: format, to: playerNodeFormat)
            $0.converters[format] = newConverter
            return newConverter
        }
    }

    // Capture appAudio and apply conversion automatically suitable for internal audio engine.
    public func capture(appAudio inputBuffer: AVAudioPCMBuffer) {
        guard let converter = converter(for: inputBuffer.format) else {
            log("Failed to get converter for input buffer format: \(inputBuffer.format)", .warning)
            return
        }

        let buffer = converter.convert(from: inputBuffer)

        let (isConnected, appNode) = _state.read {
            ($0.isInputConnected, $0.appNode)
        }

        guard isConnected, let engine = appNode.engine, engine.isRunning else {
            log("Engine is not running", .warning)
            return
        }

        appNode.scheduleBuffer(buffer)

        if !appNode.isPlaying, let engine = appNode.engine, engine.isRunning {
            appNode.play()
        }
    }
}
