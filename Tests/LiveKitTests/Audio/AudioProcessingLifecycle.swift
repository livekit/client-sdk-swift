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

import Accelerate
import AVFoundation
import Foundation
import LiveKitWebRTC

@testable import LiveKit
import XCTest

private enum CallType {
    case initialize
    case process
    case release
}

private class ProcessingDelegateTester: AudioCustomProcessingDelegate, @unchecked Sendable {
    let label: String
    struct State {
        var entries: [CallType] = []
    }

    let _state = StateSync(State())

    init(label: String) {
        self.label = label
    }

    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        _state.mutate { $0.entries.append(.initialize) }
        print("ProcessingDelegate(\(label)).Initialize(sampleRate: \(sampleRateHz), channels: \(channels))")
    }

    func audioProcessingProcess(audioBuffer: LiveKit.LKAudioBuffer) {
        _state.mutate { $0.entries.append(.initialize) }
        print("ProcessingDelegate(\(label)).Process(audioBuffer: \(audioBuffer.frames))")
    }

    func audioProcessingRelease() {
        _state.mutate { $0.entries.append(.release) }
        print("ProcessingDelegate(\(label)).Release")
    }
}

class AudioProcessingLifecycle: LKTestCase {
    func testAudioProcessing() async throws {
        let processorA = ProcessingDelegateTester(label: "A")
        let processorB = ProcessingDelegateTester(label: "B")
        // Set processing delegate
        AudioManager.shared.capturePostProcessingDelegate = processorA

        try await withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
            // Alias to Room1
            let room1 = rooms[0]
            // Publish mic
            try await room1.localParticipant.setMicrophone(enabled: true)
            do {
                // 1 secs...
                let ns = UInt64(1 * 1_000_000_000)
                try await Task.sleep(nanoseconds: ns)
            }
            AudioManager.shared.capturePostProcessingDelegate = processorB
            do {
                // 1 secs...
                let ns = UInt64(1 * 1_000_000_000)
                try await Task.sleep(nanoseconds: ns)
            }
        }

        // Remove processing delegate
        AudioManager.shared.capturePostProcessingDelegate = nil
    }
}
