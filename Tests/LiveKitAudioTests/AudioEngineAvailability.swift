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

@Suite(.serialized) struct AudioEngineAvailabilityTests {
    // Check if audio engine will stop when availability is set to .none,
    // then resume (restart) when availability is set back to .default.
    @Test func recording() throws {
        // Test without enabling VP
        try AudioManager.shared.setVoiceProcessingEnabled(false)

        // First check
        #expect(!AudioManager.shared.isEngineRunning)

        // Start
        try AudioManager.shared.startLocalRecording()
        #expect(AudioManager.shared.isEngineRunning)

        // Disable both input & output
        try AudioManager.shared.setEngineAvailability(.none)
        #expect(!AudioManager.shared.isEngineRunning)

        // Re-enable both input & output (default)
        try AudioManager.shared.setEngineAvailability(.default)
        #expect(AudioManager.shared.isEngineRunning)

        // Stop
        try AudioManager.shared.stopLocalRecording()
        #expect(!AudioManager.shared.isEngineRunning)
    }
}
