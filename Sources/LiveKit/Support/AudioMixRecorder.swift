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
    public let targetFormat: AVAudioFormat

    struct State {
        var converter: AudioConverter?
    }

    let _state = StateSync(State())

    required init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    public func scheduleBuffer(_ pcmBuffer: AVAudioPCMBuffer) {
        if pcmBuffer.format == targetFormat {
            // No conversion needed
            playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
        } else {
            let converter = _state.mutate {
                // Create converter if it doesn't exist or if the source format has changed
                if $0.converter == nil || $0.converter?.inputFormat != pcmBuffer.format {
                    print("Creating converter from \(pcmBuffer.format) to \(targetFormat)")
                    let r = AudioConverter(from: pcmBuffer.format, to: targetFormat)
                    $0.converter = r
                    return r
                }

                return $0.converter
            }

            if let converter {
                converter.convert(from: pcmBuffer)
                playerNode.scheduleBuffer(converter.outputBuffer, completionHandler: nil)
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

    private let processingFormat: AVAudioFormat

    private let maxFrameCount: Int
    private let renderBuffer: AVAudioPCMBuffer
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private let renderBlock: AVAudioEngineManualRenderingBlock

    private let renderQueue = DispatchQueue(label: "com.livekit.AudioMixRecorder.render", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "com.livekit.AudioMixRecorder.write", qos: .utility)
    private lazy var renderTimer = DispatchSource.makeTimerSource(flags: [.strict], queue: renderQueue)

    // MARK: - Lifecycle

    public init(format: AVAudioFormat, frameCount: Int = 1024) throws {
        processingFormat = format
        maxFrameCount = frameCount

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxFrameCount)) else {
            throw LiveKitError(.invalidState, message: "Failed to create PCM buffer")
        }
        renderBuffer = buffer

        try audioEngine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: AVAudioFrameCount(maxFrameCount))
        renderBlock = audioEngine.manualRenderingBlock
        // Touch main mixer to initialize
        audioEngine.mainMixerNode.outputVolume = 1.0
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    public func start(filePath: URL) throws {
        // Create settings from the format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: processingFormat.sampleRate,
            AVNumberOfChannelsKey: processingFormat.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        audioFile = try AVAudioFile(forWriting: filePath,
                                    settings: settings,
                                    commonFormat: .pcmFormatFloat32,
                                    interleaved: true)

        do {
            try audioEngine.start()
        } catch {
            log("Failed to start audio engine", .error)
            throw error
        }

        // Calculate interval based on buffer size and sample rate
        let interval = Double(maxFrameCount) / Double(processingFormat.sampleRate)

        // Create and start the render timer on the render queue
        renderTimer.schedule(deadline: .now(), repeating: interval)
        renderTimer.setEventHandler { [weak self] in
            self?.processAudioBuffer()
        }
        renderTimer.resume()
    }

    public func stop() {
        log()
        // Stop and release the timer
        renderTimer.cancel()

        // Stop all nodes
        for source in _state.sources {
            source.playerNode.stop()
        }

        // Stop the audio engine
        audioEngine.stop()

        audioFile = nil
    }

    // MARK: - Source

    public func addSource() -> AudioMixingSource {
        log()
        let source = AudioMixingSource(targetFormat: processingFormat)
        audioEngine.attach(source.playerNode)
        audioEngine.connect(source.playerNode, to: audioEngine.mainMixerNode, format: processingFormat)
        _state.mutate { $0.sources.append(source) }
        return source
    }

    // MARK: - Private Methods

    private func processAudioBuffer() {
        guard audioFile != nil else { return }

        // Reset frame length before rendering
        renderBuffer.frameLength = AVAudioFrameCount(maxFrameCount)

        let status = renderBlock(AVAudioFrameCount(maxFrameCount),
                                 renderBuffer.mutableAudioBufferList,
                                 nil)

        guard status == .success else {
            log("Failed to render")
            return
        }

        writeQueue.async { [weak self, renderBuffer] in
            guard let self, let audioFile = self.audioFile else { return }

            do {
                try audioFile.write(from: renderBuffer)
            } catch {
                log("Failed to write to audio file: \(error)")
            }
        }
    }
}
