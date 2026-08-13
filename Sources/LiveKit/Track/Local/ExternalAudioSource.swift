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
import CoreMedia
import Foundation

internal import LiveKitWebRTC

/// Options for creating an ``ExternalAudioSource``.
public struct ExternalAudioSourceOptions: Sendable {
    /// Sample rate of the audio delivered to WebRTC.
    /// Pushed buffers in other formats are converted automatically.
    public var sampleRate: Int

    /// Channel count of the audio delivered to WebRTC.
    public var channels: Int

    /// Size of the internal jitter buffer in milliseconds, a multiple of 10.
    ///
    /// The default suits bursty producers such as ReplayKit or
    /// ScreenCaptureKit: pushed audio is queued and delivered in 10 ms frames
    /// by an internal pacer, with silence on underrun.
    ///
    /// A value of `0` selects synchronous mode for callers with their own
    /// clock: each push must be exactly 10 ms and is delivered inline.
    public var queueSizeMs: Int

    public init(sampleRate: Int = 48000,
                channels: Int = 2,
                queueSizeMs: Int = 100)
    {
        self.sampleRate = sampleRate
        self.channels = channels
        self.queueSizeMs = queueSizeMs
    }
}

/// An audio source the application pushes buffers into, independent of the
/// microphone capture path.
///
/// Use ``LocalAudioTrack/createTrack(name:source:externalSource:reportStatistics:)``
/// to publish the pushed audio as its own track, e.g. app audio during screen
/// share instead of mixing it into the microphone track.
///
/// Note: WebRTC capture-side processing (echo cancellation, noise
/// suppression, gain control) is bypassed for this source by design.
public final class ExternalAudioSource: Loggable, @unchecked Sendable {
    public let options: ExternalAudioSourceOptions

    // MARK: - Internal

    let rtcSource: LKRTCExternalAudioSource

    // MARK: - Private

    private struct State {
        var converter: AudioConverter?
    }

    private let _state = StateSync(State())

    private let targetFormat: AVAudioFormat

    public init(options: ExternalAudioSourceOptions = ExternalAudioSourceOptions()) throws {
        guard let rtcSource = RTC.createExternalAudioSource(sampleRate: options.sampleRate,
                                                            channels: options.channels,
                                                            queueSizeMs: options.queueSizeMs)
        else {
            throw LiveKitError(.invalidState, message: "Failed to create external audio source, check options")
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Double(options.sampleRate),
                                         channels: AVAudioChannelCount(options.channels),
                                         interleaved: true)
        else {
            throw LiveKitError(.invalidState, message: "Failed to create audio format for options")
        }
        self.options = options
        self.rtcSource = rtcSource
        targetFormat = format
    }

    /// Pushes an audio buffer. Converted to the source's declared format
    /// (sample rate, channel count, int16) automatically when needed.
    @discardableResult
    public func push(_ buffer: AVAudioPCMBuffer) -> Bool {
        // Fast path: formats the WebRTC layer accepts directly.
        if buffer.format.sampleRate == targetFormat.sampleRate,
           buffer.format.channelCount == targetFormat.channelCount
        {
            return rtcSource.capture(buffer, completionHandler: nil)
        }

        guard let converter = converter(for: buffer.format) else {
            log("Failed to get converter for input buffer format: \(buffer.format)", .warning)
            return false
        }

        let converted = converter.convert(from: buffer)
        return rtcSource.capture(converted, completionHandler: nil)
    }

    /// Pushes audio from a `CMSampleBuffer` carrying linear PCM, e.g.
    /// ReplayKit app audio.
    @discardableResult
    public func push(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let pcm = sampleBuffer.toAVAudioPCMBuffer() else {
            log("Failed to convert CMSampleBuffer to AVAudioPCMBuffer", .warning)
            return false
        }
        return push(pcm)
    }

    /// Drops any audio buffered inside the WebRTC layer.
    public func clearBuffer() {
        rtcSource.clearBuffer()
    }

    /// Audio currently buffered inside the WebRTC layer, in milliseconds.
    public var bufferedDurationMs: Int64 {
        rtcSource.bufferedDurationMs
    }

    private func converter(for format: AVAudioFormat) -> AudioConverter? {
        _state.mutate {
            if let converter = $0.converter, converter.inputFormat == format {
                return converter
            }
            let converter = AudioConverter(from: format, to: targetFormat)
            $0.converter = converter
            return converter
        }
    }
}

// MARK: - App audio routing

/// Destination for app/screen-share audio buffers produced by capturers.
protocol AppAudioSink: AnyObject, Sendable {
    func capture(appAudio: AVAudioPCMBuffer)
}

extension ExternalAudioSource: AppAudioSink {
    func capture(appAudio buffer: AVAudioPCMBuffer) {
        push(buffer)
    }
}

extension MixerEngineObserver: AppAudioSink {}
