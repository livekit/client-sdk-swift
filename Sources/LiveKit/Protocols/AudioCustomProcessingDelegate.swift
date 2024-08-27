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

import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

public let kLiveKitKrispAudioProcessorName = "livekit_krisp_noise_cancellation"

@objc
public protocol AudioCustomProcessingDelegate {
    @objc optional
    var audioProcessingName: String { get }

    @objc
    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int)

    @objc
    func audioProcessingProcess(audioBuffer: LKAudioBuffer)

    @objc
    func audioProcessingRelease()
}

class AudioCustomProcessingDelegateAdapter: NSObject, LKRTCAudioCustomProcessingDelegate {
    // MARK: - Public

    public var target: AudioCustomProcessingDelegate? { _state.target }

    // MARK: - Internal

    let audioRenderers = MulticastDelegate<AudioRenderer>(label: "AudioRenderer")

    // MARK: - Private

    private struct State {
        weak var target: AudioCustomProcessingDelegate?
    }

    private var _state: StateSync<State>

    init(target: AudioCustomProcessingDelegate? = nil) {
        _state = StateSync(State(target: target))
    }

    public func set(target: AudioCustomProcessingDelegate?) {
        _state.mutate { $0.target = target }
    }

    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        target?.audioProcessingInitialize(sampleRate: sampleRateHz, channels: channels)
    }

    func audioProcessingProcess(audioBuffer: LKRTCAudioBuffer) {
        let lkAudioBuffer = LKAudioBuffer(audioBuffer: audioBuffer)
        target?.audioProcessingProcess(audioBuffer: lkAudioBuffer)

        // Convert to pcmBuffer and notify only if an audioRenderer is added.
        if audioRenderers.isDelegatesNotEmpty, let pcmBuffer = lkAudioBuffer.toAVAudioPCMBuffer() {
            audioRenderers.notify { $0.render?(pcmBuffer: pcmBuffer) }
        }
    }

    func audioProcessingRelease() {
        target?.audioProcessingRelease()
    }

    // Proxy the equality operators

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? AudioCustomProcessingDelegateAdapter else { return false }
        return target === other.target
    }

    override var hash: Int {
        guard let target else { return 0 }
        return ObjectIdentifier(target).hashValue
    }
}
