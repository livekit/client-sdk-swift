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

internal import LiveKitWebRTC
import Foundation

/// Returns native decoder objects unchanged so WebRTC can unwrap their native builders.
/// The class has no mutable state. Unchecked Sendable covers the non-Sendable LKRTC types.
final class VideoDecoderFactoryAdapter: NSObject, LKRTCVideoDecoderFactory, @unchecked Sendable {
    private let factory: any VideoDecoderFactory
    private let fallback: any LKRTCVideoDecoderFactory
    private let supportedRTCCodecs: [LKRTCVideoCodecInfo]

    init(factory: any VideoDecoderFactory,
         supportedCodecs: [VideoCodecInfo],
         fallback: any LKRTCVideoDecoderFactory)
    {
        self.factory = factory
        self.fallback = fallback
        var codecs = supportedCodecs
        for codec in fallback.supportedCodecs().map({ VideoCodecInfo(fromRTCType: $0) }) where !supportedCodecs.contains(where: { $0.isSameCodec(as: codec) }) {
            codecs.append(codec)
        }
        supportedRTCCodecs = codecs.map { $0.toRTCType() }
        super.init()
    }

    func createDecoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoDecoder)? {
        guard let decoder = factory.createDecoder(for: VideoCodecInfo(fromRTCType: info)) else {
            return fallback.createDecoder(info)
        }
        return VideoDecoderAdapter(decoder: decoder)
    }

    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        supportedRTCCodecs
    }
}

/// WebRTC sequences decoder calls; callback access is protected by StateSync.
final class VideoDecoderAdapter: NSObject, LKRTCVideoDecoder, Sendable, Loggable {
    private let decoder: any VideoDecoder
    private struct State {
        var callback: RTCVideoDecoderCallback?
        var didWarnUnsupportedBuffer = false
    }

    private let callback = StateSync(State())

    init(decoder: any VideoDecoder) {
        self.decoder = decoder
        super.init()
    }

    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        self.callback.mutate { $0.callback = callback }
        let box = self.callback
        decoder.setCallback { frame in
            guard frame.buffer is RTCCompatibleVideoBuffer else {
                let shouldWarn = box.mutate {
                    guard !$0.didWarnUnsupportedBuffer else { return false }
                    $0.didWarnUnsupportedBuffer = true
                    return true
                }
                if shouldWarn {
                    Self.log("Custom video decoder output has an unsupported VideoBuffer; dropping frame", .warning)
                }
                return
            }
            guard let callback = box.read({ $0.callback }) else { return }
            let rtcFrame = frame.toRTCType()
            // The ObjC bridge matches decoded output using timeStamp, not timeStampNs.
            rtcFrame.timeStamp = Int32(bitPattern: frame.rtpTimestamp)
            callback(rtcFrame)
        }
    }

    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        decoder.startDecode(numberOfCores: Int(numberOfCores)).rawValue
    }

    func decode(_ image: LKRTCEncodedImage,
                missingFrames: Bool,
                codecSpecificInfo _: (any LKRTCCodecSpecificInfo)?,
                renderTimeMs: Int64) -> Int
    {
        decoder.decode(EncodedVideoFrame(fromRTCType: image),
                       missingFrames: missingFrames,
                       renderTimeMs: renderTimeMs).rawValue
    }

    func release() -> Int {
        callback.mutate { $0.callback = nil }
        decoder.setCallback(nil)
        return decoder.releaseDecoder().rawValue
    }

    func implementationName() -> String {
        decoder.implementationName
    }
}
