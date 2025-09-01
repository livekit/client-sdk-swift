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

@preconcurrency import AVFoundation

internal import LiveKitWebRTC

public final class MixerEngineObserver: AudioEngineObserver, Loggable {
    public var next: (any AudioEngineObserver)? {
        get { _state.next }
        set { _state.mutate { $0.next = newValue } }
    }

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

    // MARK: - Internal

    var appAudioNode: AVAudioPlayerNode {
        _state.read { $0.appNode }
    }

    var micAudioNode: AVAudioPlayerNode {
        _state.read { $0.micNode }
    }

    struct State {
        var next: (any AudioEngineObserver)?

        // AppAudio
        let appNode = AVAudioPlayerNode()
        let appMixerNode = AVAudioMixerNode()

        // Not connected for device rendering mode.
        let micNode = AVAudioPlayerNode()
        let micMixerNode = AVAudioMixerNode()

        // Reference to mainMixerNode
        weak var mainMixerNode: AVAudioMixerNode?
        var outputVolume: Float = 1.0

        // Internal states
        var isInputConnected: Bool = false

        // Cached converters
        var converters: [AVAudioFormat: AudioConverter] = [:]

        // Reference to engine format
        var engineFormat: AVAudioFormat?
    }

    let _state = StateSync(State())

    public init() {}

    public func setNext(_ handler: any AudioEngineObserver) {
        next = handler
    }

    public func engineDidCreate(_ engine: AVAudioEngine) -> Int {
        let (appNode, appMixerNode, micNode, micMixerNode) = _state.read {
            ($0.appNode, $0.appMixerNode, $0.micNode, $0.micMixerNode)
        }

        engine.attach(appNode)
        engine.attach(appMixerNode)
        engine.attach(micNode)
        engine.attach(micMixerNode)

        // Invoke next
        return next?.engineDidCreate(engine) ?? 0
    }

    public func engineWillRelease(_ engine: AVAudioEngine) -> Int {
        // Invoke next
        let nextResult = next?.engineWillRelease(engine)

        let (appNode, appMixerNode, micNode, micMixerNode) = _state.read {
            ($0.appNode, $0.appMixerNode, $0.micNode, $0.micMixerNode)
        }

        engine.detach(appNode)
        engine.detach(appMixerNode)
        engine.detach(micNode)
        engine.detach(micMixerNode)

        return nextResult ?? 0
    }

    public func engineWillConnectInput(_ engine: AVAudioEngine, src: AVAudioNode?, dst: AVAudioNode, format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        // Get the main mixer
        guard let mainMixerNode = context[kLKRTCAudioEngineInputMixerNodeKey] as? AVAudioMixerNode else {
            // If failed to get main mixer, call next and return.
            return next?.engineWillConnectInput(engine, src: src, dst: dst, format: format, context: context) ?? 0
        }

        // Read nodes from state lock.
        let (appNode, appMixerNode, micNode, micMixerNode) = _state.read {
            ($0.appNode, $0.appMixerNode, $0.micNode, $0.micMixerNode)
        }

        log("Connecting app -> appMixer -> mainMixer")
        // appAudio -> appAudioMixer -> mainMixer
        engine.connect(appNode, to: appMixerNode, format: format)
        engine.connect(appMixerNode, to: mainMixerNode, format: format)

        // src is not null if device rendering mode.
        if let src {
            log("Connecting src (device) to micMixer -> mainMixer")
            // mic (device) -> micMixer -> mainMixer
            engine.connect(src, to: micMixerNode, format: format)
        }

        log("Connecting micAudio (player) to micMixer -> mainMixer")
        // mic (player) -> micMixer -> mainMixer
        engine.connect(micNode, to: micMixerNode, format: format)
        // Always connect micMixer to mainMixer
        engine.connect(micMixerNode, to: mainMixerNode, format: format)

        _state.mutate {
            if let previousEngineFormat = $0.engineFormat, previousEngineFormat != format {
                // Clear cached converters when engine format changes
                $0.converters.removeAll()
            }
            $0.engineFormat = format
            $0.isInputConnected = true
        }

        // Invoke next
        return next?.engineWillConnectInput(engine, src: src, dst: dst, format: format, context: context) ?? 0
    }

    public func engineWillConnectOutput(_ engine: AVAudioEngine, src: AVAudioNode, dst: AVAudioNode?, format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        // Get the main mixer
        let outputVolume = _state.mutate {
            $0.mainMixerNode = engine.mainMixerNode
            return $0.outputVolume
        }

        engine.mainMixerNode.outputVolume = outputVolume

        return next?.engineWillConnectOutput(engine, src: src, dst: dst, format: format, context: context) ?? 0
    }
}

extension MixerEngineObserver {
    // Create or use cached AudioConverter.
    func converter(for format: AVAudioFormat) -> AudioConverter? {
        _state.mutate {
            guard let engineFormat = $0.engineFormat else { return nil }

            if let converter = $0.converters[format] {
                return converter
            }

            let newConverter = AudioConverter(from: format, to: engineFormat)
            $0.converters[format] = newConverter
            return newConverter
        }
    }

    // Capture appAudio and apply conversion automatically suitable for internal audio engine.
    public func capture(appAudio inputBuffer: AVAudioPCMBuffer) {
        let (isConnected, appNode) = _state.read {
            ($0.isInputConnected, $0.appNode)
        }

        guard isConnected, let engine = appNode.engine, engine.isRunning else { return }

        // Create or update the converter if needed
        let converter = converter(for: inputBuffer.format)

        guard let converter else { return }

        let buffer = converter.convert(from: inputBuffer)
        appNode.scheduleBuffer(buffer)

        if !appNode.isPlaying {
            appNode.play()
        }
    }
}
