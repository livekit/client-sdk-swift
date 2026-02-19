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

// swiftlint:disable file_length

@preconcurrency import AVFoundation
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
import LiveKitWebRTC
import LKObjCHelpers

@Suite(.serialized, .tags(.audio, .e2e)) struct AudioEngineTests {
    #if !targetEnvironment(simulator)
    // Test if mic is authorized. Only works on device.
    @Test func micAuthorized() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status != .authorized {
            let result = await AVCaptureDevice.requestAccess(for: .audio)
            #expect(result)
        }

        #expect(status == .authorized)
    }
    #endif

    // Test if state transitions pass internal checks.
    @Test func stateTransitions() {
        let adm = AudioManager.shared
        // Start Playout
        adm.initPlayout()
        #expect(adm.isPlayoutInitialized)
        adm.startPlayout()
        #expect(adm.isPlaying)

        // Start Recording
        adm.initRecording()
        #expect(adm.isRecordingInitialized)
        adm.startRecording()
        #expect(adm.isRecording)

        // Stop engine
        adm.stopRecording()
        #expect(!adm.isRecording)
        #expect(!adm.isRecordingInitialized)

        adm.stopPlayout()
        #expect(!adm.isPlaying)
        #expect(!adm.isPlayoutInitialized)
    }

    @Test func recordingAlwaysPreparedMode() async throws {
        let adm = AudioManager.shared

        // Ensure initially not initialized.
        #expect(!adm.isRecordingInitialized)

        // Ensure recording is initialized after set to true.
        try await adm.setRecordingAlwaysPreparedMode(true)

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        #expect(session.category == .playAndRecord)
        #expect(session.mode == .videoChat || session.mode == .voiceChat)
        #endif

        adm.initRecording()
        #expect(adm.isRecordingInitialized)

        adm.startRecording()
        #expect(adm.isRecordingInitialized)

        adm.stopRecording()
        #expect(!adm.isRecordingInitialized)
    }

    @Test func configureDucking() {
        AudioManager.shared.isAdvancedDuckingEnabled = false
        #expect(!AudioManager.shared.isAdvancedDuckingEnabled)

        AudioManager.shared.isAdvancedDuckingEnabled = true
        #expect(AudioManager.shared.isAdvancedDuckingEnabled)

        if #available(iOS 17, macOS 14.0, visionOS 1.0, *) {
            AudioManager.shared.duckingLevel = .default
            #expect(AudioManager.shared.duckingLevel == .default)

            AudioManager.shared.duckingLevel = .min
            #expect(AudioManager.shared.duckingLevel == .min)

            AudioManager.shared.duckingLevel = .max
            #expect(AudioManager.shared.duckingLevel == .max)

            AudioManager.shared.duckingLevel = .mid
            #expect(AudioManager.shared.duckingLevel == .mid)
        }
    }

    // Test start generating local audio buffer without joining to room.
    @Test func preconnectAudioBuffer() async throws {
        // Phase 1: Verify audio frames are received without a room connection
        try await confirmation("Should receive audio frame") { audioFrameConfirm in
            let audioFrameWatcher = AudioTrackWatcher(id: "notifier01") { _ in
                audioFrameConfirm()
            }

            let localMicTrack = LocalAudioTrack.createTrack()
            localMicTrack.add(audioRenderer: audioFrameWatcher)

            Task {
                print("Starting local recording...")
                try AudioManager.shared.startLocalRecording()
            }

            // Wait for audio frame...
            print("Waiting for first audio frame...")
            try? await Task.sleep(nanoseconds: 10_000_000_000)

            localMicTrack.remove(audioRenderer: audioFrameWatcher)
        }

        // Phase 2: Connect to room and publish mic
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
            print("Publishing mic...")
            try await rooms[0].localParticipant.setMicrophone(enabled: true)
        }
    }

    // Test the manual rendering mode (no-device mode) of AVAudioEngine based AudioDeviceModule.
    // In manual rendering, no device access will be initialized such as mic and speaker.
    @Test func manualRenderingModeSineGenerator() async throws {
        // Set manual rendering mode...
        try AudioManager.shared.setManualRenderingMode(true)

        // Attach sine wave generator when engine requests input node.
        // inputMixerNode will automatically convert to RTC's internal format (int16).
        AudioManager.shared.set(engineObservers: [SineWaveNodeHook()])

        // Check if manual rendering mode is set...
        let isManualRenderingMode = AudioManager.shared.isManualRenderingMode
        print("manualRenderingMode: \(isManualRenderingMode)")
        #expect(isManualRenderingMode)

        let recorder = try TestAudioRecorder()

        // Note: AudioCaptureOptions will not be applied since track is not published.
        let track = LocalAudioTrack.createTrack(options: .noProcessing)
        track.add(audioRenderer: recorder)

        // Start engine...
        try AudioManager.shared.startLocalRecording()

        // Render for 5 seconds...
        try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)

        recorder.close()
        print("Written to: \(recorder.filePath)")

        // Stop engine
        try AudioManager.shared.stopLocalRecording()

        // Play the recorded file...
        let player = try AVAudioPlayer(contentsOf: recorder.filePath)
        #expect(player.play(), "Failed to start audio playback")
        while player.isPlaying {
            try? await Task.sleep(nanoseconds: 1 * 100_000_000) // 10ms
        }
    }

    @Test func manualRenderingModeAudioFile() async throws {
        // Sample audio
        let url = try #require(URL(string: "https://github.com/rafaelreis-hotmart/Audio-Sample-files/raw/refs/heads/master/sample.wav"))

        print("Downloading sample audio from \(url)...")
        let (downloadedLocalUrl, _) = try await URLSession.shared.downloadBackport(from: url)

        // Move the file to a new temporary location with a more descriptive name, if desired
        let tempLocalUrl = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try FileManager.default.moveItem(at: downloadedLocalUrl, to: tempLocalUrl)
        print("Original file: \(tempLocalUrl)")

        let audioFile = try AVAudioFile(forReading: tempLocalUrl)
        let audioFileFormat = audioFile.processingFormat // AVAudioFormat object

        print("Sample Rate: \(audioFileFormat.sampleRate)")
        print("Channel Count: \(audioFileFormat.channelCount)")
        print("Common Format: \(audioFileFormat.commonFormat)")
        print("Interleaved: \(audioFileFormat.isInterleaved)")

        // Set manual rendering mode...
        try AudioManager.shared.setManualRenderingMode(true)

        let playerNodeHook = PlayerNodeHook(playerNodeFormat: audioFileFormat)
        AudioManager.shared.set(engineObservers: [playerNodeHook])

        // Check if manual rendering mode is set...
        let isManualRenderingMode = AudioManager.shared.isManualRenderingMode
        print("manualRenderingMode: \(isManualRenderingMode)")
        #expect(isManualRenderingMode)

        let recorder = try TestAudioRecorder()

        // Note: AudioCaptureOptions will not be applied since track is not published.
        let track = LocalAudioTrack.createTrack(options: .noProcessing)
        track.add(audioRenderer: recorder)

        // Start engine...
        try AudioManager.shared.startLocalRecording()

        let scheduleAndPlayTask = Task {
            print("Will scheduleFile")
            await playerNodeHook.playerNode.scheduleFile(audioFile, at: nil)
            print("Did scheduleFile")
        }

        // Wait for audio file to be consumed...
        playerNodeHook.playerNode.play()
        await scheduleAndPlayTask.value

        recorder.close()
        print("Processed file: \(recorder.filePath)")

        // Stop engine
        try AudioManager.shared.stopLocalRecording()

        // Play the recorded file...
        let player = try AVAudioPlayer(contentsOf: recorder.filePath)
        #expect(player.play(), "Failed to start audio playback")
        while player.isPlaying {
            try? await Task.sleep(nanoseconds: 1 * 100_000_000) // 10ms
        }
    }

    @Test func manualRenderingModePublishAudio() async throws {
        // Sample audio
        let url = try #require(URL(string: "https://github.com/rafaelreis-hotmart/Audio-Sample-files/raw/refs/heads/master/sample.wav"))

        print("Downloading sample audio from \(url)...")
        let (downloadedLocalUrl, _) = try await URLSession.shared.downloadBackport(from: url)

        // Move the file to a new temporary location with a more descriptive name, if desired
        let tempLocalUrl = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try FileManager.default.moveItem(at: downloadedLocalUrl, to: tempLocalUrl)
        print("Original file: \(tempLocalUrl)")

        let audioFile = try AVAudioFile(forReading: tempLocalUrl)
        let audioFileFormat = audioFile.processingFormat // AVAudioFormat object

        print("Sample Rate: \(audioFileFormat.sampleRate)")
        print("Channel Count: \(audioFileFormat.channelCount)")
        print("Common Format: \(audioFileFormat.commonFormat)")
        print("Interleaved: \(audioFileFormat.isInterleaved)")

        // Set manual rendering mode...
        try AudioManager.shared.setManualRenderingMode(true)

        // Check if manual rendering mode is set...
        let isManualRenderingMode = AudioManager.shared.isManualRenderingMode
        print("manualRenderingMode: \(isManualRenderingMode)")
        #expect(isManualRenderingMode)

        let readBuffer = try #require(AVAudioPCMBuffer(pcmFormat: audioFileFormat, frameCapacity: 480))

        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
            let room1 = rooms[0]

            let ns5 = UInt64(20 * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns5)

            try await room1.localParticipant.setMicrophone(enabled: true)

            repeat {
                do {
                    try audioFile.read(into: readBuffer, frameCount: 480)
                    print("Read buffer frame capacity: \(readBuffer.frameLength)")
                    AudioManager.shared.mixer.capture(appAudio: readBuffer)
                } catch {
                    print("Read buffer failed with error: \(error)")
                    break
                }
            } while true

            let ns = UInt64(10 * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns)
        }
    }

    #if os(iOS) || os(visionOS) || os(tvOS)
    @Test func backwardCompatibility() throws {
        struct TestState {
            var trackState: AudioManager.TrackState = .none
        }
        let _testState = StateSync(TestState())

        AudioManager.shared.customConfigureAudioSessionFunc = { newState, oldState in
            print("New trackState: \(newState.trackState), Old trackState: \(oldState.trackState)")
            _testState.mutate { $0.trackState = newState.trackState }
        }

        // Configure session since we are setting a empty config func.
        let config = AudioSessionConfiguration.playAndRecordSpeaker
        let session = LKRTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try session.setConfiguration(config.toRTCType(), active: true)
        session.unlockForConfiguration()

        #expect(_testState.trackState == .none)

        AudioManager.shared.initPlayout()
        #expect(_testState.trackState == .remoteOnly)

        AudioManager.shared.initRecording()
        #expect(_testState.trackState == .localAndRemote)

        AudioManager.shared.stopRecording()
        #expect(_testState.trackState == .remoteOnly)

        AudioManager.shared.stopPlayout()
        #expect(_testState.trackState == .none)
    }

    @Test func defaultAudioSessionConfiguration() {
        AudioManager.shared.initPlayout()
        AudioManager.shared.initRecording()
        AudioManager.shared.stopRecording()
        AudioManager.shared.stopPlayout()
    }
    #endif

    // Test if audio engine can start while another AVAudioEngine is running with VP enabled.
    @Test func multipleAudioEngine() async throws {
        // Start sample audio engine with VP.
        let engine = AVAudioEngine()
        try engine.outputNode.setVoiceProcessingEnabled(true)

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let generator = SineWaveSourceNode(frequency: 480, sampleRate: outputFormat.sampleRate)
        let monoFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: outputFormat.sampleRate, channels: 1))
        engine.attach(generator)
        engine.connect(generator, to: engine.mainMixerNode, format: monoFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)

        print("isVoiceProcessingEnabled: \(engine.outputNode.isVoiceProcessingEnabled)")

        try engine.start()
        print("isRunning: \(engine.isRunning)")

        // Attempt to start ADM's audio engine while another engine is running first.
        try AudioManager.shared.startLocalRecording()

        // Render for 5 seconds...
        try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
    }
}

final class SineWaveNodeHook: AudioEngineObserver, @unchecked Sendable {
    var next: (any LiveKit.AudioEngineObserver)?

    let sineWaveNode = SineWaveSourceNode()

    func engineDidCreate(_ engine: AVAudioEngine) -> Int {
        engine.attach(sineWaveNode)
        return 0
    }

    func engineWillRelease(_ engine: AVAudioEngine) -> Int {
        engine.detach(sineWaveNode)
        return 0
    }

    func engineWillConnectInput(_ engine: AVAudioEngine, src _: AVAudioNode?, dst: AVAudioNode, format: AVAudioFormat, context _: [AnyHashable: Any]) -> Int {
        print("engineWillConnectInput")
        engine.connect(sineWaveNode, to: dst, format: format)
        return 0
    }
}

final class PlayerNodeHook: AudioEngineObserver, @unchecked Sendable {
    var next: (any LiveKit.AudioEngineObserver)?

    let playerNode = AVAudioPlayerNode()
    let playerMixerNode = AVAudioMixerNode()
    let playerNodeFormat: AVAudioFormat

    init(playerNodeFormat: AVAudioFormat) {
        self.playerNodeFormat = playerNodeFormat
    }

    func engineDidCreate(_ engine: AVAudioEngine) -> Int {
        engine.attach(playerNode)
        engine.attach(playerMixerNode)
        return 0
    }

    func engineWillRelease(_ engine: AVAudioEngine) -> Int {
        engine.detach(playerNode)
        engine.detach(playerMixerNode)
        return 0
    }

    func engineWillConnectInput(_ engine: AVAudioEngine, src _: AVAudioNode?, dst: AVAudioNode, format: AVAudioFormat, context _: [AnyHashable: Any]) -> Int {
        print("engineWillConnectInput")
        engine.connect(playerNode, to: playerMixerNode, format: playerNodeFormat)
        engine.connect(playerMixerNode, to: dst, format: format)
        return 0
    }
}
