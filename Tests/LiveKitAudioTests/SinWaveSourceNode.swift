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

class SineWaveSourceNode: AVAudioSourceNode, @unchecked Sendable {
    private let sampleRate: Double
    private let frequency: Double

    init(frequency: Double = 400.0, sampleRate: Double = 48000.0) {
        self.frequency = frequency
        self.sampleRate = sampleRate

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        let twoPi = 2 * Float.pi
        let amplitude: Float = 0.5
        var currentPhase: Float = 0.0
        let phaseIncrement: Float = (twoPi / Float(sampleRate)) * Float(frequency)

        let renderBlock: AVAudioSourceNodeRenderBlock = { _, _, frameCount, audioBufferList in
            print("AVAudioSourceNodeRenderBlock frameCount: \(frameCount)")

            // Accessing the AudioBufferList manually
            let audioBuffers = audioBufferList.pointee

            // Assuming a single channel setup
            guard audioBuffers.mNumberBuffers > 0 else {
                return noErr
            }

            let audioBuffer = audioBuffers.mBuffers // Access first buffer
            guard let dataPointer = audioBuffer.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }

            let bufferPointer = UnsafeMutableBufferPointer(start: dataPointer, count: Int(frameCount))

            // Generate sine wave samples
            for frame in 0 ..< bufferPointer.count {
                let value = sin(currentPhase) * amplitude
                currentPhase += phaseIncrement
                if currentPhase >= twoPi { currentPhase -= twoPi }
                if currentPhase < 0.0 { currentPhase += twoPi }

                bufferPointer[frame] = value
            }

            return noErr
        }

        super.init(format: format, renderBlock: renderBlock)
    }
}
