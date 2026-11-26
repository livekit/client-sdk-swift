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

internal import LiveKitFFI

extension AudioPublishOptions {
    func ffiOptions() throws -> LiveKitFFI.TrackPublishOptions {
        var ffi = LiveKitFFI.TrackPublishOptions(source: .microphone, dtx: dtx, red: red, stream: streamName ?? "")
        ffi.preconnectBuffer = preConnect
        if let encoding {
            guard encoding.maxBitrate > 0, encoding.bitratePriority == nil, encoding.networkPriority == nil else {
                throw LiveKitError(.invalidParameter, message: "Core audio encoding requires a positive bitrate and does not expose RTP priorities")
            }
            ffi.audioEncoding = .init(maxBitrate: UInt64(encoding.maxBitrate))
        }
        return ffi
    }
}

extension VideoEncoding {
    func ffiEncoding() throws -> LiveKitFFI.VideoEncoding {
        guard maxBitrate > 0, maxFps > 0, bitratePriority == nil, networkPriority == nil else {
            throw LiveKitError(.invalidParameter, message: "Core video encoding requires positive bitrate/FPS and does not expose RTP priorities")
        }
        return .init(maxBitrate: UInt64(maxBitrate), maxFramerate: Double(maxFps))
    }
}

extension VideoPublishOptions {
    func ffiOptions(screenShare: Bool) throws -> LiveKitFFI.TrackPublishOptions {
        guard preferredBackupCodec == nil else {
            throw LiveKitError(.invalidParameter, message: "Core publishing does not expose a backup codec")
        }
        var ffi = LiveKitFFI.TrackPublishOptions(source: screenShare ? .screenshare : .camera, simulcast: simulcast, stream: streamName ?? "")
        ffi.videoEncoding = try (screenShare ? screenShareEncoding : encoding)?.ffiEncoding()
        let layers = screenShare ? screenShareSimulcastLayers : simulcastLayers
        if !layers.isEmpty {
            guard layers.count <= 2 else {
                throw LiveKitError(.invalidParameter, message: "Core custom simulcast accepts at most two lower layers")
            }
            ffi.simulcastLayers = try layers.map {
                guard $0.dimensions.width > 0, $0.dimensions.height > 0 else {
                    throw LiveKitError(.invalidParameter, message: "Simulcast dimensions must be positive")
                }
                return try .init(encoding: $0.encoding.ffiEncoding(), width: UInt32($0.dimensions.width), height: UInt32($0.dimensions.height))
            }
        }
        ffi.videoCodec = try ffiCodec()
        ffi.degradationPreference = ffiDegradationPreference()
        return ffi
    }

    private func ffiCodec() throws -> LiveKitFFI.VideoCodec {
        let name = preferredCodec?.name
        switch name {
        case nil, "vp8": return .vp8
        case "h264": return .h264
        case "h265": return .h265
        case "vp9": return .vp9
        case "av1": return .av1
        default: throw LiveKitError(.invalidParameter, message: "Unsupported core video codec")
        }
    }

    private func ffiDegradationPreference() -> LiveKitFFI.DegradationPreference? {
        switch degradationPreference {
        case .auto: nil
        case .disabled, .maintainFramerateAndResolution: .maintainFramerateAndResolution
        case .maintainFramerate: .maintainFramerate
        case .maintainResolution: .maintainResolution
        case .balanced: .balanced
        }
    }
}
