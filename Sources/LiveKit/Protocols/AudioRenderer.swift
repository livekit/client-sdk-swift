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
    @objc
    func render(pcmBuffer: AVAudioPCMBuffer)
}

class AudioRendererAdapter: NSObject, LKRTCAudioRenderer {
    private weak var target: AudioRenderer?
    private let targetHashValue: Int

    init(target: AudioRenderer) {
        self.target = target
        targetHashValue = ObjectIdentifier(target).hashValue
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        target?.render(pcmBuffer: pcmBuffer)
    }

    // Proxy the equality operators
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? AudioRendererAdapter else { return false }
        return targetHashValue == other.targetHashValue
    }

    override var hash: Int {
        targetHashValue
    }
}
