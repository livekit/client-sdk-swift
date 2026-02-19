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
@testable import LiveKit
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif
import LiveKitWebRTC

@Suite(.serialized, .tags(.audio)) struct AudioManagerTests {
    // Test legacy audio device module's startLocalRecording().
    @Test func startLocalRecordingLegacyADM() async throws {
        // Use legacy ADM
        try AudioManager.set(audioDeviceModuleType: .platformDefault)

        // Ensure audio session category is `.playAndRecord`.
        #if os(iOS) || os(tvOS) || os(visionOS)
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoChat, options: [])
        #endif

        let recorder = try TestAudioRecorder()

        let audioTrack = LocalAudioTrack.createTrack()
        audioTrack.add(audioRenderer: recorder)

        // Start recording
        try AudioManager.shared.startLocalRecording()

        // Record for 5 seconds...
        try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)

        recorder.close()
        AudioManager.shared.stopRecording()

        // Play the recorded file...
        let player = try AVAudioPlayer(contentsOf: recorder.filePath)
        #expect(player.play(), "Failed to start audio playback")
        while player.isPlaying {
            try? await Task.sleep(nanoseconds: 1 * 100_000_000) // 10ms
        }
    }

    // Confirm different behavior of Voice-Processing-Mute between macOS and other platforms.
    @Test func confirmGlobalVpMuteStateOniOS() throws {
        // Ensure audio session category is `.playAndRecord`.
        #if !os(macOS)
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoChat, options: [])
        #endif

        let e1 = AVAudioEngine()
        try e1.inputNode.setVoiceProcessingEnabled(true)

        let e2 = AVAudioEngine()
        try e2.inputNode.setVoiceProcessingEnabled(true)

        // e1, e2 both un-muted
        #expect(!e1.inputNode.isVoiceProcessingInputMuted)
        #expect(!e2.inputNode.isVoiceProcessingInputMuted)

        // Mute e1, but e2 should be unaffected.
        e1.inputNode.isVoiceProcessingInputMuted = true
        #expect(e1.inputNode.isVoiceProcessingInputMuted)

        #if os(macOS)
        // On macOS, e2 isn't affected by e1's muted state.
        #expect(!e2.inputNode.isVoiceProcessingInputMuted)
        #else
        // On Other platforms, e2 is affected by e1's muted state.
        #expect(e2.inputNode.isVoiceProcessingInputMuted)
        #endif
    }

    // The Voice-Processing-Input-Muted state appears to be a global state within the app.
    // We make sure that after the Room gets cleaned up, this state is back to un-muted since
    // it will interfere with audio recording later in the app.
    //
    // Previous RTC libs would fail this test since, RTC was always invoking AudioDeviceModule::SetMicrophoneMuted(true)
    @Test func voiceProcessingInputMuted() async throws {
        // Set VP muted state.
        func setVoiceProcessingInputMuted(_ muted: Bool) throws {
            let e = AVAudioEngine()
            // VP always needs to be enabled to read / write the vp muted state
            try e.inputNode.setVoiceProcessingEnabled(true)
            e.inputNode.isVoiceProcessingInputMuted = muted
            #expect(e.inputNode.isVoiceProcessingInputMuted == muted)
            print("Set vp muted to \(muted), and verified it is \(e.inputNode.isVoiceProcessingInputMuted)")
        }

        // Confirm if is VP muted.
        func isVoiceProcessingInputMuted() throws -> Bool {
            let e = AVAudioEngine()
            // VP always needs to be enabled to read / write the vp muted state
            try e.inputNode.setVoiceProcessingEnabled(true)
            return e.inputNode.isVoiceProcessingInputMuted
        }

        // Ensure audio session category is `.playAndRecord`.
        #if os(iOS) || os(tvOS) || os(visionOS)
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoChat, options: [])
        #endif

        do {
            // Should *not* be VP-muted at this point.
            let isVpMuted = try isVoiceProcessingInputMuted()
            print("isVpMuted: \(isVpMuted)")
            #expect(!isVpMuted)
        }

        let adm = AudioManager.shared

        // Start recording, mic indicator should turn on.
        print("Starting local recording...")
        try adm.startLocalRecording()

        // Wait for 3 seconds...
        try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)

        // Set mute, mic indicator should turn off.
        adm.isMicrophoneMuted = true

        // Wait for 3 seconds...
        try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)

        try adm.stopLocalRecording()

        // Wait for 1 second...
        try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)

        do {
            // Should *not* be VP-muted at this point.
            let isVpMuted = try isVoiceProcessingInputMuted()
            print("isVpMuted: \(isVpMuted)")
            #expect(!isVpMuted)
        }
    }
}
