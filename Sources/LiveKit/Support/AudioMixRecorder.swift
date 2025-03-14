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

import AVFAudio
import Foundation

public class AudioMixingSource: AudioRenderer {
    public let playerNode = AVAudioPlayerNode()
    public let engineFormat: AVAudioFormat

    struct State {
        var converter: AudioConverter?
    }

    let _state = StateSync(State())

    required init(engineFormat: AVAudioFormat) {
        self.engineFormat = engineFormat
    }

    public func scheduleBuffer(_ pcmBuffer: AVAudioPCMBuffer) {
        // Fast path: no conversion needed
        if pcmBuffer.format == engineFormat {
            playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
            if !playerNode.isPlaying {
                playerNode.play()
            }
            return
        }

        // Conversion path
        let converter = _state.mutate {
            // Create converter if it doesn't exist or if the source format has changed
            if $0.converter == nil || $0.converter?.inputFormat != pcmBuffer.format {
                let newConverter = AudioConverter(from: pcmBuffer.format, to: engineFormat)
                $0.converter = newConverter
                return newConverter
            }
            return $0.converter
        }

        if let converter {
            converter.convert(from: pcmBuffer)
            // Copy the converted segment from buffer and schedule it.
            let segment = converter.outputBuffer.copySegment()
            playerNode.scheduleBuffer(segment, completionHandler: nil)
            if !playerNode.isPlaying {
                playerNode.play()
            }
        }
    }

    // MARK: - AudioRenderer

    public func render(pcmBuffer: AVAudioPCMBuffer) {
        scheduleBuffer(pcmBuffer)
    }
}

public class AudioMixRecorder: Loggable {
    // MARK: - Properties

    struct State {
        var sources: [AudioMixingSource] = []
    }

    let _state = StateSync(State())

    private let maxFrameCount: Int

    private let audioEngine = AVAudioEngine()
    private let renderBuffer: AVAudioPCMBuffer
    private let engineFormat: AVAudioFormat
    private var audioFile: AVAudioFile?
    private let renderBlock: AVAudioEngineManualRenderingBlock

    // Use higher priority for render queue to ensure timely audio processing
    private let renderQueue = DispatchQueue(label: "com.livekit.AudioMixRecorder.render", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "com.livekit.AudioMixRecorder.write", qos: .utility)
    private lazy var renderTimer = DispatchSource.makeTimerSource(flags: [.strict], queue: renderQueue)

    // MARK: - Lifecycle

    public init(filePath: URL, audioSettings: [String: Any], frameCount: Int = 1024) throws {
        // Create audio file with cached settings
        audioFile = try AVAudioFile(forWriting: filePath,
                                    settings: audioSettings)
        // Use same processing format for engine's render format
        engineFormat = audioFile!.processingFormat
        maxFrameCount = frameCount
        // Create render buffer
        guard let newBuffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: AVAudioFrameCount(maxFrameCount)) else {
            throw LiveKitError(.invalidState, message: "Failed to create PCM buffer")
        }
        renderBuffer = newBuffer
        // Enable realtime rendering
        try audioEngine.enableManualRenderingMode(.realtime, format: engineFormat, maximumFrameCount: AVAudioFrameCount(maxFrameCount))
        // Cache the render block
        renderBlock = audioEngine.manualRenderingBlock
        // Initialize main mixer
        audioEngine.mainMixerNode.outputVolume = 1.0
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    public func start() throws {
        guard !audioEngine.isRunning else { return }

        try audioEngine.start()
        // Calculate interval based on buffer size and sample rate
        let interval = Double(maxFrameCount) / Double(engineFormat.sampleRate)

        // Configure and start the render timer
        renderTimer.schedule(deadline: .now(), repeating: interval)
        renderTimer.setEventHandler { [weak self] in
            self?._render()
        }
        renderTimer.resume()

        // Start all nodes if already attached
        for source in _state.sources {
            source.playerNode.play()
        }
    }

    public func stop() {
        renderTimer.cancel()
        for source in _state.sources {
            source.playerNode.stop()
        }
        audioEngine.stop()
        audioFile = nil
    }

    // MARK: - Source

    public func addSource() -> AudioMixingSource {
        let source = AudioMixingSource(engineFormat: engineFormat)
        audioEngine.attach(source.playerNode)
        audioEngine.connect(source.playerNode, to: audioEngine.mainMixerNode, format: engineFormat)

        _state.mutate { $0.sources.append(source) }
        return source
    }

    public func removeAllSources() {
        _state.mutate {
            for source in $0.sources {
                source.playerNode.stop()
                audioEngine.detach(source.playerNode)
            }

            $0.sources.removeAll()
        }
    }

    // MARK: - Private Methods

    private func _render() {
        guard audioFile != nil else { return }

        // Reset frame length before rendering
        renderBuffer.frameLength = AVAudioFrameCount(maxFrameCount)

        // Render audio
        let status = renderBlock(AVAudioFrameCount(maxFrameCount),
                                 renderBuffer.mutableAudioBufferList,
                                 nil)

        guard status == .success else {
            log("Failed to render audio", .error)
            return
        }

        // Capture necessary values to avoid strong reference cycle
        writeQueue.async { [weak self, renderBuffer, audioFile = self.audioFile] in
            guard let audioFile else { return }

            do {
                try audioFile.write(from: renderBuffer)
            } catch {
                self?.log("Failed to write to audio file: \(error)", .error)
            }
        }
    }
}
