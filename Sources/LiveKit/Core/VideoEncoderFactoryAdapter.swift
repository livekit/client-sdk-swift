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
    private let supportedRTCCodecs: [LKRTCVideoCodecInfo]
    private let supportedCodecNames: Set<String>

    /// - Parameter supportedCodecs: The codecs validated when the factory was set.
    ///   Read once here rather than from the factory again, so the list that was
    ///   checked is the list that gets advertised and enforced.
    init(factory: any VideoEncoderFactory, supportedCodecs: [VideoCodecInfo]) {
        self.factory = factory
        supportedRTCCodecs = supportedCodecs.map { $0.toRTCType() }
        supportedCodecNames = Set(supportedCodecs.map { $0.name.uppercased() })
        super.init()
    }

    func createEncoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoEncoder)? {
        let codec = VideoCodecInfo(fromRTCType: info)
        // The simulcast factory asks the primary for whatever codec was negotiated,
        // including ones only the built in fallback advertised. Declining here
        // routes those to the fallback and keeps unbridgeable codecs such as VP8
        // away from the packetizer.
        guard supportedCodecNames.contains(codec.name.uppercased()) else { return nil }
        guard let encoder = factory.createEncoder(for: codec) else { return nil }

        return VideoEncoderAdapter(encoder: encoder, codec: codec)
    }

    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        supportedRTCCodecs
    }
}

/// Bridges a public ``VideoEncoder`` to WebRTC's `RTCVideoEncoder`.
final class VideoEncoderAdapter: NSObject, LKRTCVideoEncoder, @unchecked Sendable {
    /// Holds the current WebRTC callback behind one stable closure handed to the
    /// encoder.
    ///
    /// WebRTC re-registers a fresh callback without an intervening nil whenever the
    /// simulcast adapter's stream contexts are moved, so the closure stays the same
    /// across consecutive non nil registrations and only the stored block changes.
    /// After `clear()` a later registration attaches a new closure. A delivery that
    /// finds the box cleared is dropped, while one that already copied the block out
    /// may still finish, so teardown relies on the encoder honoring the
    /// ``VideoEncoder/releaseEncoder()`` contract of delivering nothing afterwards.
    /// The callback runs outside the lock: the block only holds a raw pointer to
    /// WebRTC's native callback, so a lock could not extend its lifetime, and
    /// holding one across the packetize and send path would make `release()` wait
    /// on every frame.
    private final class CallbackBox: @unchecked Sendable {
        private struct State {
            var callback: RTCVideoEncoderCallback?
            var isAttached = false
        }

        private let state = StateSync(State())

        /// Stores `callback` and reports whether the encoder still needs to be
        /// handed the forwarding closure.
        func set(_ callback: RTCVideoEncoderCallback?) -> Bool {
            state.mutate {
                $0.callback = callback
                guard callback != nil, !$0.isAttached else { return false }
                $0.isAttached = true
                return true
            }
        }

        func clear() {
            state.mutate {
                $0.callback = nil
                $0.isAttached = false
            }
        }

        func invoke(_ image: LKRTCEncodedImage, _ info: any LKRTCCodecSpecificInfo) -> Bool {
            // Copied out so the callback runs outside the lock.
            guard let callback = state.read({ $0.callback }) else { return false }
            return callback(image, info)
        }
    }

    private let encoder: any VideoEncoder
    private let codec: VideoCodecInfo
    private let callbackBox = CallbackBox()

    init(encoder: any VideoEncoder, codec: VideoCodecInfo) {
        self.encoder = encoder
        self.codec = codec
        super.init()
    }

    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        guard callback != nil else {
            callbackBox.clear()
            encoder.setCallback(nil)
            return
        }
        guard callbackBox.set(callback) else { return }
        let box = callbackBox
        let codec = codec
        encoder.setCallback { frame in
            let (image, info) = frame.toRTCType(codec: codec)
            return box.invoke(image, info)
        }
    }

    func startEncode(with settings: LKRTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        encoder.startEncode(with: VideoEncoderSettings(fromRTCType: settings),
                            numberOfCores: Int(numberOfCores)).rawValue
    }

    func release() -> Int {
        callbackBox.clear()
        return encoder.releaseEncoder().rawValue
    }

    func encode(_ frame: LKRTCVideoFrame,
                codecSpecificInfo _: (any LKRTCCodecSpecificInfo)?,
                frameTypes: [NSNumber]) -> Int
    {
        guard let lkFrame = frame.toLKType() else {
            // Lets the simulcast adapter switch to the built in encoder instead of
            // dropping every frame with a buffer the SDK cannot map.
            return VideoEncoderStatus.fallbackSoftware.rawValue
        }
        // The array is positional, one entry per simulcast stream, so arity is
        // preserved and anything not a known video frame type becomes a delta.
        let types = frameTypes.map {
            LKRTCFrameType(rawValue: $0.uintValue)
                .flatMap { EncodedVideoFrame.FrameType(fromRTCType: $0) } ?? .delta
        }
        return encoder.encode(lkFrame, frameTypes: types).rawValue
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        Int32(truncatingIfNeeded: encoder.setBitrate(bitrateKbit, framerate: framerate).rawValue)
    }

    func implementationName() -> String {
        encoder.implementationName
    }

    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? {
        encoder.scalingSettings?.toRTCType()
    }

    // Not exposed on the public protocol: the bridge always reports 1 to WebRTC
    // regardless of this value, so encoders must accept any resolution.
    var resolutionAlignment: Int { 1 }

    var applyAlignmentToAllSimulcastLayers: Bool { false }

    var supportsNativeHandle: Bool {
        encoder.supportsNativeHandle
    }
}
