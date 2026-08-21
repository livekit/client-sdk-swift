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

struct AudioProcessingOptionsTests {
    @Test func captureOptionsProjectToProcessingOptions() {
        let options = AudioCaptureOptions(
            echoCancellation: true,
            autoGainControl: false,
            noiseSuppression: true,
            highpassFilter: false,
            echoCancellationMode: .software,
            autoGainControlMode: .platform,
            noiseSuppressionMode: .automatic,
            highpassFilterMode: .software,
        )

        let expected = AudioProcessingOptions(
            echoCancellation: true,
            autoGainControl: false,
            noiseSuppression: true,
            highpassFilter: false,
            echoCancellationMode: .software,
            autoGainControlMode: .platform,
            noiseSuppressionMode: .automatic,
            highpassFilterMode: .software,
        )
        #expect(options.audioProcessing == expected)
    }

    @Test func noProcessingPresetsAgree() {
        #expect(AudioCaptureOptions.noProcessing.audioProcessing == AudioProcessingOptions.noProcessing)
    }

    @Test func legacyCaptureInitializerDefaultsToAutomaticModes() {
        let options = AudioCaptureOptions(
            echoCancellation: false,
            autoGainControl: true,
            noiseSuppression: false,
            highpassFilter: true,
            typingNoiseDetection: true,
        )

        #expect(options.echoCancellation == false)
        #expect(options.autoGainControl == true)
        #expect(options.noiseSuppression == false)
        #expect(options.highpassFilter == true)
        #expect(options.echoCancellationMode == .automatic)
        #expect(options.autoGainControlMode == .automatic)
        #expect(options.noiseSuppressionMode == .automatic)
        #expect(options.highpassFilterMode == .automatic)
        #expect(options.typingNoiseDetection == true)
    }

    @Test func effectSpecificModesMapToConstraints() {
        #expect(EchoCancellationMode.platform.toConstraintValue() == "platform")
        #expect(AutoGainControlMode.software.toConstraintValue() == "software")
        #expect(NoiseSuppressionMode.automatic.toConstraintValue() == "auto")
        #expect(HighpassFilterMode.software.toConstraintValue() == "software")
        #expect(HighpassFilterMode.automatic.toConstraintValue() == "auto")
    }

    @Test func componentRequestsPreserveEffectSpecificModeTypes() {
        let echoCancellation = AudioProcessingComponentRequest(
            isEnabled: true,
            mode: EchoCancellationMode.platform,
        )
        let highpassFilter = AudioProcessingComponentRequest(
            isEnabled: true,
            mode: HighpassFilterMode.software,
        )

        #expect(echoCancellation.mode == .platform)
        #expect(highpassFilter.mode == .software)
    }

    @Test func defaultOptionsRequestPlatformEchoNoisePath() {
        #expect(AudioProcessingOptions().requestsPlatformEchoNoisePath == true)
    }

    @Test func softwareModesDoNotRequestPlatformEchoNoisePath() {
        let options = AudioProcessingOptions(
            echoCancellationMode: .software,
            autoGainControlMode: .software,
            noiseSuppressionMode: .software,
        )
        #expect(options.requestsPlatformEchoNoisePath == false)
    }

    @Test func singleNonSoftwareComponentRequestsPlatformEchoNoisePath() {
        let options = AudioProcessingOptions(
            echoCancellationMode: .software,
            noiseSuppressionMode: .automatic,
        )
        #expect(options.requestsPlatformEchoNoisePath == true)
    }

    @Test func disabledComponentsDoNotRequestPlatformEchoNoisePath() {
        #expect(AudioProcessingOptions.noProcessing.requestsPlatformEchoNoisePath == false)

        let disabledButPlatformMode = AudioProcessingOptions(
            echoCancellation: false,
            noiseSuppression: false,
            echoCancellationMode: .platform,
            noiseSuppressionMode: .platform,
        )
        #expect(disabledButPlatformMode.requestsPlatformEchoNoisePath == false)
    }

    @Test func agcAloneDoesNotRequestPlatformEchoNoisePath() {
        let options = AudioProcessingOptions(
            echoCancellation: false,
            autoGainControl: true,
            noiseSuppression: false,
            autoGainControlMode: .platform,
        )
        #expect(options.requestsPlatformEchoNoisePath == false)
    }
}
