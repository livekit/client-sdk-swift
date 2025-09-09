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

@preconcurrency import AVFAudio
import Foundation

/// `AudioMixRecorder` provides real-time audio recording capabilities using AVAudioEngine.
///
/// This class allows recording audio from multiple sources to a file in real-time. If no audio
/// buffer is provided during recording, it will record silence. The recorder maintains a list
/// of audio sources that can be added or removed dynamically, even while recording is in progress.
///
/// Audio settings must be compatible with the settings for `AVAudioRecorder`.
///
/// Each audio source implements the `AudioRenderer` protocol, making it compatible with both
/// `RemoteAudioTrack` and `LocalAudioTrack` through their `add(audioRenderer:)` methods.
///
/// It is currently not possible to re-use the instance after calling ``AudioMixRecorder/stop()``.
///
/// ## Usage
///
/// ```swift
/// // Create recorder with output file path and audio settings
/// let recordFilePath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recording.aac")
/// let audioSettings: [String: Any] = [
///     AVFormatIDKey: kAudioFormatMPEG4AAC,
///     AVSampleRateKey: 16000,
///     AVNumberOfChannelsKey: 1,
///     AVLinearPCMBitDepthKey: 32,
///     AVLinearPCMIsFloatKey: true,
///     AVLinearPCMIsNonInterleaved: false,
///     AVLinearPCMIsBigEndianKey: false,
/// ]
///
/// let recorder = try AudioMixRecorder(filePath: recordFilePath, audioSettings: audioSettings)
///
/// // Start recording
/// try recorder.start()
///
/// // Add a remote audio source
/// remoteAudioTrack.add(audioRenderer: recorder.addSource())
///
/// // Add a local audio source
/// localAudioTrack.add(audioRenderer: recorder.addSource())
///
/// // Record for some time...
///
/// // Stop recording
/// recorder.stop()
/// ```
///
/// Audio sources can be added or removed at any time, including while recording is active.
/// When no audio is being provided by any source, the recorder will capture silence.

public class AudioMixRecorder: Loggable, @unchecked Sendable {
    // MARK: - Public

    /// The format used internally by engine & recorder.
    public let processingFormat: AVAudioFormat

    public var isRecording: Bool {
        audioEngine.isRunning
    }

    public var sources: [AudioMixRecorderSource] {
        _state.read { $0.sources }
    }

    // MARK: - Private

    struct State {
        var sources: [AudioMixRecorderSource] = []
    }

    private let _state = StateSync(State())

    private let maxFrameCount: Int

    private let audioEngine = AVAudioEngine()
    private let renderBuffer: AVAudioPCMBuffer
    private let renderBlock: AVAudioEngineManualRenderingBlock

    // Use higher priority for render queue to ensure timely audio processing
    private let renderQueue = DispatchQueue(label: "com.livekit.AudioMixRecorder.render", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "com.livekit.AudioMixRecorder.write", qos: .utility)

    private var audioFile: AVAudioFile?
    private var renderTimer: DispatchSourceTimer?

    // MARK: - Lifecycle

    public init(filePath: URL, audioSettings: [String: Any], frameCount: Int = 1024) throws {
        // Create audio file with cached settings
        audioFile = try AVAudioFile(forWriting: filePath,
                                    settings: audioSettings)
        // Use same processing format for engine's render format
        processingFormat = audioFile!.processingFormat
        maxFrameCount = frameCount
        // Create render buffer
        guard let newBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(maxFrameCount)) else {
            throw LiveKitError(.invalidState, message: "Failed to create PCM buffer")
        }
        renderBuffer = newBuffer
        // Enable realtime rendering
        try audioEngine.enableManualRenderingMode(.realtime, format: processingFormat, maximumFrameCount: AVAudioFrameCount(maxFrameCount))
        // Cache the render block
        renderBlock = audioEngine.manualRenderingBlock
        // Initialize main mixer
        audioEngine.mainMixerNode.outputVolume = 1.0
    }

    deinit {
        log()
        if audioEngine.isRunning {
            stop()
        }
    }

    // MARK: - Public Methods

    public func start() throws {
        guard !audioEngine.isRunning else {
            log("Already running", .warning)
            return
        }
        log()

        try audioEngine.start()
        // Calculate interval based on buffer size and sample rate
        let interval = Double(maxFrameCount) / Double(processingFormat.sampleRate)
        startRenderTimer(interval: interval)

        // Start all nodes if already attached
        for source in _state.sources {
            source.play()
        }
    }

    public func stop() {
        guard audioEngine.isRunning else {
            log("Already stopped", .warning)
            return
        }
        log()

        stopRenderTimer()
        for source in _state.sources {
            source.stop()
        }
        audioEngine.stop()
        audioFile = nil
    }

    // MARK: - Source

    @discardableResult
    public func addSource() -> AudioMixRecorderSource {
        log()

        let source = AudioMixRecorderSource(processingFormat: processingFormat)
        audioEngine.attach(source.playerNode)
        audioEngine.connect(source.playerNode, to: audioEngine.mainMixerNode, format: processingFormat)

        _state.mutate { $0.sources.append(source) }
        return source
    }

    public func removeAllSources() {
        log()

        _state.mutate {
            for source in $0.sources {
                source.cleanup()
                audioEngine.detach(source.playerNode)
            }

            $0.sources = []
        }
    }

    // MARK: - Private Methods

    private func startRenderTimer(interval: Double) {
        let timer = DispatchSource.makeTimerSource(flags: [.strict], queue: renderQueue)
        // Configure and start the render timer
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?._render() }
        timer.resume()
        renderTimer = timer
    }

    private func stopRenderTimer() {
        renderTimer?.cancel()
        renderTimer = nil
    }

    private func _render() {
        guard audioFile != nil else {
            log("Audio file is already closed", .error)
            return
        }

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
            guard let self else { return }
            guard let audioFile else {
                log("Audio file is already closed", .error)
                return
            }

            do {
                try audioFile.write(from: renderBuffer)
            } catch {
                log("Failed to write to audio file: \(error)", .error)
            }
        }
    }
}

public class AudioMixRecorderSource: Loggable, AudioRenderer, @unchecked Sendable {
    public let processingFormat: AVAudioFormat
    let playerNode = AVAudioPlayerNode()

    private struct State {
        var converter: AudioConverter?
    }

    private let _state = StateSync(State())

    init(processingFormat: AVAudioFormat) {
        self.processingFormat = processingFormat
    }

    deinit {
        log()
        cleanup()
    }

    public func cleanup() {
        stop()
        _state.mutate { $0.converter = nil }
    }

    // MARK: - Internal

    func play() {
        guard let engine = playerNode.engine, engine.isRunning, !playerNode.isPlaying else { return }
        playerNode.play()
    }

    func stop() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
    }

    // MARK: - Public

    public func scheduleFile(_ file: AVAudioFile) {
        playerNode.scheduleFile(file, at: nil)
        play()
    }

    public func scheduleBuffer(_ pcmBuffer: AVAudioPCMBuffer) {
        // Fast path: no conversion needed
        if pcmBuffer.format == processingFormat {
            playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
            play()
            return
        }

        // Conversion path
        let converter = _state.mutate {
            // Create converter if it doesn't exist or if the source format has changed
            if $0.converter == nil || $0.converter?.inputFormat != pcmBuffer.format {
                let newConverter = AudioConverter(from: pcmBuffer.format, to: processingFormat)
                $0.converter = newConverter
                return newConverter
            }
            return $0.converter
        }

        if let converter {
            let buffer = converter.convert(from: pcmBuffer)
            playerNode.scheduleBuffer(buffer, completionHandler: nil)
            play()
        }
    }

    // MARK: - AudioRenderer

    public func render(pcmBuffer: AVAudioPCMBuffer) {
        scheduleBuffer(pcmBuffer)
    }
}
