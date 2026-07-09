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

@testable import LiveKit
import Testing

@Suite(.tags(.audio)) struct AudioManagerAdmResultTests {
    let audioManager = AudioManager.shared

    @Test func successCodeDoesNotThrow() throws {
        try audioManager.checkAdmResult(code: 0)
    }

    // The WebRTC AudioEngineDevice returns -9000 when microphone permission is not granted.
    // This must map to `.deviceAccessDenied`, not the generic `.audioEngine`.
    @Test func insufficientDevicePermissionMapsToDeviceAccessDenied() throws {
        let error = try #require(throws: LiveKitError.self) {
            try audioManager.checkAdmResult(code: kAudioEngineErrorInsufficientDevicePermission)
        }
        #expect(error.type == .deviceAccessDenied)
    }

    // The WebRTC AudioEngineDevice returns -9001 when the audio session category cannot record.
    @Test func invalidCategoryMapsToAudioSession() throws {
        let error = try #require(throws: LiveKitError.self) {
            try audioManager.checkAdmResult(code: kAudioEngineErrorAudioSessionInvalidCategory)
        }
        #expect(error.type == .audioSession)
    }

    @Test func failedToConfigureAudioSessionMapsToAudioSession() throws {
        let error = try #require(throws: LiveKitError.self) {
            try audioManager.checkAdmResult(code: kAudioEngineErrorFailedToConfigureAudioSession)
        }
        #expect(error.type == .audioSession)
    }

    @Test func unrecognizedCodeMapsToAudioEngine() throws {
        let error = try #require(throws: LiveKitError.self) {
            try audioManager.checkAdmResult(code: -1234)
        }
        #expect(error.type == .audioEngine)
    }
}
