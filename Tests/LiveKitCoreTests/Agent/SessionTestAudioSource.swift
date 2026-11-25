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

import AVFAudio
import Foundation
@testable import LiveKit

/// Exercises the real audio pipeline without accessing microphone or speaker hardware.
@MainActor
enum SessionTestAudioSource {
    static func withAudio(_ body: @MainActor () async throws -> Void) async throws {
        try await RTC.run { try AudioManager.shared.setManualRenderingMode(true) }
        let feeding = Task {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buffer.frameLength = 480
            let channel = buffer.floatChannelData![0]
            for index in 0 ..< 480 {
                channel[index] = 0.4 * sin(Float(index) * 2 * .pi * 400 / 48000)
            }
            while !Task.isCancelled {
                AudioManager.shared.mixer.capture(appAudio: buffer)
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        do {
            try await body()
        } catch {
            feeding.cancel()
            await feeding.value
            try await RTC.run { try AudioManager.shared.setManualRenderingMode(false) }
            throw error
        }
        feeding.cancel()
        await feeding.value
        try await RTC.run { try AudioManager.shared.setManualRenderingMode(false) }
    }
}
