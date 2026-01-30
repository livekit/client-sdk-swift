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

internal import LiveKitWebRTC

/// Audio track for app audio during screen sharing.
/// Bypasses the AudioDeviceModule completely to preserve stereo.
///
/// Unlike LocalAudioTrack which uses the ADM (mono, with voice processing),
/// this track pushes audio directly to the encoder via PushAudioSource.
/// This allows stereo app audio to be sent without affecting microphone audio.
@objc
public class LocalAppAudioTrack: Track, LocalTrackProtocol, AudioTrackProtocol, @unchecked Sendable {
    private let pushSource: LKRTCPushAudioSource

    /// Number of audio channels (typically 2 for stereo).
    @objc
    public let channelCount: Int

    /// Sample rate in Hz (typically 48000).
    @objc
    public let sampleRate: Double

    /// Creates a new app audio track for stereo audio during screen sharing.
    ///
    /// - Parameters:
    ///   - name: Track name, defaults to `Track.screenShareAudioName`.
    ///   - channelCount: Number of channels, defaults to 2 (stereo).
    ///   - sampleRate: Sample rate in Hz, defaults to 48000.
    ///   - reportStatistics: Whether to report track statistics.
    /// - Returns: A configured `LocalAppAudioTrack` instance.
    public static func createTrack(
        name: String = Track.screenShareAudioName,
        channelCount: Int = 2,
        sampleRate: Double = 48000,
        reportStatistics: Bool = false
    ) -> LocalAppAudioTrack {
        let pushSource = LKRTCPushAudioSource(sampleRate: Int32(sampleRate), channels: Int32(channelCount))
        let rtcTrack = RTC.createAudioTrack(pushSource: pushSource)
        rtcTrack.isEnabled = true

        return LocalAppAudioTrack(
            name: name,
            source: .screenShareAudio,
            track: rtcTrack,
            pushSource: pushSource,
            channelCount: channelCount,
            sampleRate: sampleRate,
            reportStatistics: reportStatistics
        )
    }

    init(
        name: String,
        source: Track.Source,
        track: LKRTCMediaStreamTrack,
        pushSource: LKRTCPushAudioSource,
        channelCount: Int,
        sampleRate: Double,
        reportStatistics: Bool
    ) {
        self.pushSource = pushSource
        self.channelCount = channelCount
        self.sampleRate = sampleRate

        super.init(
            name: name,
            kind: .audio,
            source: source,
            track: track,
            reportStatistics: reportStatistics
        )
    }

    struct State {
        var converter: AudioConverter?
        var ringBuffer: AVAudioPCMRingBuffer?
    }

    private let _appAudioState = StateSync(State())

    /// Push stereo PCM buffer directly to WebRTC's audio encoding pipeline.
    /// This bypasses the ADM completely - audio goes directly to the encoder.
    ///
    /// - Parameter buffer: An `AVAudioPCMBuffer` containing the audio data.
    ///   Float32 format is automatically converted to Int16.
    @objc
    public func push(_ buffer: AVAudioPCMBuffer) {
        // Ensure we have a converter to Target Format (Int16 Interleaved)
        // We convert to Int16 Interleaved in Swift to bypass any format issues in the native layer.
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: buffer.format.sampleRate,
                                         channels: buffer.format.channelCount,
                                         interleaved: true)!

        let (converter, ringBuffer) = _appAudioState.mutate { state -> (AudioConverter?, AVAudioPCMRingBuffer?) in
            if state.converter?.inputFormat != buffer.format || state.converter?.outputFormat != targetFormat {
                guard let newConverter = AudioConverter(from: buffer.format, to: targetFormat) else {
                    return (nil, nil)
                }
                state.converter = newConverter
            }

            if state.ringBuffer?.buffer.format != targetFormat {
                state.ringBuffer = AVAudioPCMRingBuffer(format: targetFormat)
            }

            return (state.converter, state.ringBuffer)
        }

        guard let converter, let ringBuffer else { return }

        // Convert and append to ring buffer
        let convertedBuffer = converter.convert(from: buffer)
        ringBuffer.append(audioBuffer: convertedBuffer)

        // WebRTC ACM expects exactly 10ms of data
        let frames10ms = AVAudioFrameCount(targetFormat.sampleRate / 100)

        // Read and push 10ms chunks
        while let frame = ringBuffer.read(frames: frames10ms) {
            if let int16Data = frame.int16ChannelData {
                pushSource.pushData(int16Data[0],
                                    bitsPerSample: Int32(16),
                                    sampleRate: Int32(targetFormat.sampleRate),
                                    channels: Int(targetFormat.channelCount),
                                    frames: Int(frame.frameLength))
            }
        }
    }

    /// Push raw PCM data directly to WebRTC's audio encoding pipeline.
    /// This bypasses the ADM completely - audio goes directly to the encoder.
    ///
    /// - Parameters:
    ///   - data: Pointer to interleaved PCM data (16-bit signed integers).
    ///   - bitsPerSample: Bits per sample (typically 16).
    ///   - sampleRate: Sample rate in Hz.
    ///   - channels: Number of channels.
    ///   - frames: Number of audio frames.
    public func pushData(
        _ data: UnsafeRawPointer,
        bitsPerSample: Int32,
        sampleRate: Int32,
        channels: Int,
        frames: Int
    ) {
        // Push directly to PushAudioSource -> encoder sink (bypasses ADM!)
        pushSource.pushData(data, bitsPerSample: bitsPerSample, sampleRate: sampleRate, channels: channels, frames: frames)
    }

    public func mute() async throws {
        try await super._mute()
    }

    public func unmute() async throws {
        try await super._unmute()
    }

    // MARK: - LocalTrackProtocol

    override func startCapture() async throws {
        // No-op: we don't use AudioManager/ADM for app audio
    }

    override func stopCapture() async throws {
        // No-op
    }

    // MARK: - AudioTrackProtocol

    public func add(audioRenderer _: AudioRenderer) {
        // App audio renderers not yet supported
    }

    public func remove(audioRenderer _: AudioRenderer) {
        // App audio renderers not yet supported
    }
}

public extension LocalAppAudioTrack {
    var publishOptions: TrackPublishOptions? { super._state.lastPublishOptions }
    var publishState: Track.PublishState { super._state.publishState }
}
