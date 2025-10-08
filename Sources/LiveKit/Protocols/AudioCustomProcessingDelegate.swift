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
import Foundation

internal import LiveKitWebRTC

public let kLiveKitKrispAudioProcessorName = "livekit_krisp_noise_cancellation"

/// Used to modify audio buffers before they are sent to the network or played to the user
@objc
public protocol AudioCustomProcessingDelegate: Sendable {
    /// An optional identifier for the audio processor implementation.
    /// This can be used to identify different types of audio processing (e.g. noise cancellation).
    /// Generally you can leave this as the default value.
    @objc optional
    var audioProcessingName: String { get }

    /// Provides the sample rate and number of channels to configure your delegate for processing
    @objc
    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int)

    /// Provides a chunk of audio data that can be modified in place
    @objc
    func audioProcessingProcess(audioBuffer: LKAudioBuffer)

    /// Called when the audio processing is no longer needed so it may clean up any resources
    @objc
    func audioProcessingRelease()
}

class AudioCustomProcessingDelegateAdapter: MulticastDelegate<AudioRenderer>, @unchecked Sendable, LKRTCAudioCustomProcessingDelegate {
    // MARK: - Public

    let label: String
    var target: AudioCustomProcessingDelegate? { _state.target }

    // MARK: - Private

    private struct State {
        var target: AudioCustomProcessingDelegate?
    }

    private var _state = StateSync(State())

    private let rtcDelegateGetter: () -> LKRTCAudioCustomProcessingDelegate?
    private let rtcDelegateSetter: (LKRTCAudioCustomProcessingDelegate?) -> Void

    func set(target: AudioCustomProcessingDelegate?, oldTarget: AudioCustomProcessingDelegate? = nil) {
        // Clear WebRTC delegate first if there's an old target - this triggers audioProcessingRelease() on it
        if oldTarget != nil {
            rtcDelegateSetter(nil)
        }
        _state.mutate { $0.target = target }
        updateRTCConnection()
    }

    init(label: String,
         rtcDelegateGetter: @escaping () -> LKRTCAudioCustomProcessingDelegate?,
         rtcDelegateSetter: @escaping (LKRTCAudioCustomProcessingDelegate?) -> Void)
    {
        self.label = label
        self.rtcDelegateGetter = rtcDelegateGetter
        self.rtcDelegateSetter = rtcDelegateSetter
        super.init(label: "AudioCustomProcessingDelegateAdapter.\(label)")
        log("label: \(label)")
    }

    // Override add/remove to manage RTC connection
    override func add(delegate: AudioRenderer) {
        super.add(delegate: delegate)
        updateRTCConnection()
    }

    override func remove(delegate: AudioRenderer) {
        super.remove(delegate: delegate)
        updateRTCConnection()
    }

    private func updateRTCConnection() {
        let shouldBeConnected = target != nil || isDelegatesNotEmpty
        let isConnected = rtcDelegateGetter() === self

        if shouldBeConnected, !isConnected {
            // Connect
            rtcDelegateSetter(self)
        } else if !shouldBeConnected, isConnected {
            // Disconnect
            rtcDelegateSetter(nil)
        }
    }

    // MARK: - AudioCustomProcessingDelegate

    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        target?.audioProcessingInitialize(sampleRate: sampleRateHz, channels: channels)
    }

    func audioProcessingProcess(audioBuffer: LKRTCAudioBuffer) {
        let lkAudioBuffer = LKAudioBuffer(audioBuffer: audioBuffer)
        target?.audioProcessingProcess(audioBuffer: lkAudioBuffer)

        // Convert to pcmBuffer and notify only if an audioRenderer is added.
        if isDelegatesNotEmpty, let pcmBuffer = lkAudioBuffer.toAVAudioPCMBuffer() {
            notify { $0.render(pcmBuffer: pcmBuffer) }
        }
    }

    func audioProcessingRelease() {
        target?.audioProcessingRelease()
    }
}
