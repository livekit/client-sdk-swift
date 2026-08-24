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

import Foundation

internal import LiveKitWebRTC

/// Bridges a public ``VideoEncoderFactory`` to WebRTC's `RTCVideoEncoderFactory`.
final class VideoEncoderFactoryAdapter: NSObject, LKRTCVideoEncoderFactory, @unchecked Sendable {
    private let factory: any VideoEncoderFactory

    init(factory: any VideoEncoderFactory) {
        self.factory = factory
        super.init()
    }

    func createEncoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoEncoder)? {
        guard let encoder = factory.createEncoder(for: VideoCodecInfo(fromRTCType: info)) else { return nil }
        return VideoEncoderAdapter(encoder: encoder)
    }

    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        factory.supportedCodecs.map { $0.toRTCType() }
    }
}

/// Bridges a public ``VideoEncoder`` to WebRTC's `RTCVideoEncoder`.
final class VideoEncoderAdapter: NSObject, LKRTCVideoEncoder, @unchecked Sendable {
    private let encoder: any VideoEncoder

    init(encoder: any VideoEncoder) {
        self.encoder = encoder
        super.init()
    }

    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        guard let callback else {
            encoder.setCallback(nil)
            return
        }
        // WebRTC's encoded image callback is safe to invoke from any thread.
        nonisolated(unsafe) let rtcCallback = callback
        encoder.setCallback { frame in
            let (image, info) = frame.toRTCType()
            return rtcCallback(image, info)
        }
    }

    func startEncode(with settings: LKRTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        encoder.startEncode(with: VideoEncoderSettings(fromRTCType: settings),
                            numberOfCores: Int(numberOfCores)).rawValue
    }

    func release() -> Int {
        encoder.releaseEncoder().rawValue
    }

    func encode(_ frame: LKRTCVideoFrame,
                codecSpecificInfo _: (any LKRTCCodecSpecificInfo)?,
                frameTypes: [NSNumber]) -> Int
    {
        guard let lkFrame = frame.toLKType() else {
            return VideoEncoderStatus.invalidParameter.rawValue
        }
        let types = frameTypes.compactMap {
            LKRTCFrameType(rawValue: $0.uintValue).flatMap { EncodedVideoFrame.FrameType(fromRTCType: $0) }
        }
        return encoder.encode(lkFrame, frameTypes: types).rawValue
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        Int32(encoder.setBitrate(bitrateKbit, framerate: framerate).rawValue)
    }

    func implementationName() -> String {
        encoder.implementationName
    }

    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? {
        encoder.scalingSettings?.toRTCType()
    }

    var resolutionAlignment: Int {
        encoder.resolutionAlignment
    }

    var applyAlignmentToAllSimulcastLayers: Bool {
        encoder.applyAlignmentToAllSimulcastLayers
    }

    var supportsNativeHandle: Bool {
        encoder.supportsNativeHandle
    }
}
