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

import AVFoundation
import CoreMedia

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

@objc
public protocol AudioRenderer {
    /// CMSampleBuffer for this track.
    @objc optional
    func render(sampleBuffer: CMSampleBuffer)

    @objc optional
    func render(pcmBuffer: AVAudioPCMBuffer)
}

class AudioRendererAdapter: NSObject, LKRTCAudioRenderer {
    private weak var target: AudioRenderer?

    init(target: AudioRenderer) {
        self.target = target
    }

    func render(sampleBuffer: CMSampleBuffer) {
        target?.render?(sampleBuffer: sampleBuffer)
    }

    // Proxy the equality operators

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? AudioRendererAdapter else { return false }
        return target === other.target
    }

    override var hash: Int {
        guard let target else { return 0 }
        return ObjectIdentifier(target).hashValue
    }
}
