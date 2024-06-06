/*
 * Copyright 2024 LiveKit
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
import XCTest

class AudioProcessingTests: XCTestCase, AudioCustomProcessingDelegate {
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
            XCTFail("Failed to convert audio buffer to AVAudioPCMBuffer")
            return
        }

        print("pcm: \(pcm), " + "sampleRate: \(pcm.format.sampleRate), " + "channels: \(pcm.format.channelCount), " + "frameLength: \(pcm.frameLength), " + "frameCapacity: \(pcm.frameCapacity)")

        XCTAssert(pcm.format.sampleRate == _initSampleRate)
        XCTAssert(pcm.format.channelCount == _initChannels)
    }

    func audioProcessingRelease() {
        //
    }

    func testConvertAudioBufferToPCM() async throws {
        try await withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
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
}
