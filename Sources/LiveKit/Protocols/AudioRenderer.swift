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

@preconcurrency import AVFoundation
import CoreMedia

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

/// Used to observe audio buffers before playback, e.g. for visualization, recording, etc
/// - Note: AudioRenderer is not suitable for buffer modification. If you need to modify the buffer, use `AudioCustomProcessingDelegate` instead.
@objc
public protocol AudioRenderer: Sendable {
    @objc
    func render(pcmBuffer: AVAudioPCMBuffer)
}

class AudioRendererAdapter: MulticastDelegate<AudioRenderer>, @unchecked Sendable, LKRTCAudioRenderer {
    //
    typealias Delegate = AudioRenderer

    init() {
        super.init(label: "AudioRendererAdapter")
    }

    // MARK: - LKRTCAudioRenderer

    func render(pcmBuffer: AVAudioPCMBuffer) {
        notify { $0.render(pcmBuffer: pcmBuffer) }
    }
}
