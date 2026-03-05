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

import Accelerate
import AVFoundation
import Foundation
@testable import LiveKit
import LiveKitWebRTC
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

@Suite(.serialized, .tags(.audio, .e2e)) final class AudioProcessingTests: AudioCustomProcessingDelegate, @unchecked Sendable {
    var _initSampleRate: Double = 0.0
    var _initChannels: Int = 0

    func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        // 48000, 1
        print("sampleRate: \(sampleRate), channels: \(channels)")
        _initSampleRate = Double(sampleRate)
        _initChannels = channels
    }

    func audioProcessingProcess(audioBuffer: LiveKit.LKAudioBuffer) {
        guard let pcm = audioBuffer.toAVAudioPCMBuffer() else {
            Issue.record("Failed to convert audio buffer to AVAudioPCMBuffer")
            return
        }

        print("pcm: \(pcm), " + "sampleRate: \(pcm.format.sampleRate), " + "channels: \(pcm.format.channelCount), " + "frameLength: \(pcm.frameLength), " + "frameCapacity: \(pcm.frameCapacity)")

        #expect(pcm.format.sampleRate == _initSampleRate)
        #expect(pcm.format.channelCount == _initChannels)
    }

    func audioProcessingRelease() {
        //
    }

    @Test func convertAudioBufferToPCM() async throws {
        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
            // Alias to Room1
            let room1 = rooms[0]
            // Set processing delegate
            AudioManager.shared.capturePostProcessingDelegate = self
            // Publish mic
            try await room1.localParticipant.setMicrophone(enabled: true)
            // 3 secs...
            let ns = UInt64(5 * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns)
        }
    }

    @Test func optionsAppliedToAudioProcessingModule() async throws {
        // Disable Apple VPIO.
        AudioManager.shared.isVoiceProcessingBypassed = true

        try await TestEnvironment.withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
            // Alias to Room1
            let room1 = rooms[0]

            let allOnOptions = AudioCaptureOptions(
                echoCancellation: true,
                autoGainControl: true,
                noiseSuppression: true,
                highpassFilter: true
            )

            let allOffOptions = AudioCaptureOptions(
                echoCancellation: false,
                autoGainControl: false,
                noiseSuppression: false,
                highpassFilter: false
            )

            let pub1 = try await room1.localParticipant.setMicrophone(enabled: true, captureOptions: allOnOptions)
            guard let pub1 else {
                Issue.record("Publication is nil")
                return
            }

            let ns = UInt64(3 * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns)

            // Directly read config from the apm
            let allOnConfigResult = RTC.audioProcessingModule.config
            print("Config result for all on: \(allOnConfigResult.toDebugString()))")
            #expect(allOnConfigResult.isEchoCancellationEnabled)
            #expect(allOnConfigResult.isNoiseSuppressionEnabled)
            #expect(allOnConfigResult.isAutoGainControl1Enabled)
            #expect(allOnConfigResult.isHighpassFilterEnabled)

            try await room1.localParticipant.unpublish(publication: pub1)

            let pub2 = try await room1.localParticipant.setMicrophone(enabled: true, captureOptions: allOffOptions)
            guard let pub2 else {
                Issue.record("Publication is nil")
                return
            }

            try await Task.sleep(nanoseconds: ns)

            // Directly read config from the apm
            let allOffConfigResult = RTC.audioProcessingModule.config
            print("Config result for all off: \(allOffConfigResult.toDebugString())")
            #expect(!allOffConfigResult.isEchoCancellationEnabled)
            #expect(!allOffConfigResult.isNoiseSuppressionEnabled)
            #expect(!allOffConfigResult.isAutoGainControl1Enabled)
            #expect(!allOffConfigResult.isHighpassFilterEnabled)

            try await room1.localParticipant.unpublish(publication: pub2)
        }
    }
}
