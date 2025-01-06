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

import AVFAudio

class SineWaveSourceNode: AVAudioSourceNode {
    private let sampleRate: Double
    private let frequency: Double

    init(frequency: Double = 400.0, sampleRate: Double = 48000.0) {
        self.frequency = frequency
        self.sampleRate = sampleRate

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        var currentPhase = 0.0
        let phaseIncrement = 2.0 * Double.pi * frequency / sampleRate

        let renderBlock: AVAudioSourceNodeRenderBlock = { _, _, frameCount, audioBufferList in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let ptr = ablPointer[0].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_InvalidParameter
            }

            // Generate sine wave samples
            for frame in 0 ..< Int(frameCount) {
                ptr[frame] = Float(sin(currentPhase))

                // Update the phase
                currentPhase += phaseIncrement

                // Keep phase within [0, 2π] range using fmod for stability
                currentPhase = fmod(currentPhase, 2.0 * Double.pi)
            }

            return noErr
        }

        super.init(format: format, renderBlock: renderBlock)
    }
}
