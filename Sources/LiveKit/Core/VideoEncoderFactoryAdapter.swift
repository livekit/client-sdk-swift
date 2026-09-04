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

    init(factory: any VideoEncoderFactory) {
        self.factory = factory
        supportedRTCCodecs = factory.supportedCodecs.map { $0.toRTCType() }
        super.init()
    }

    func createEncoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoEncoder)? {
        guard let encoder = factory.createEncoder(for: VideoCodecInfo(fromRTCType: info)) else { return nil }
        return VideoEncoderAdapter(encoder: encoder)
    }

    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        supportedRTCCodecs
    }
}

/// Bridges a public ``VideoEncoder`` to WebRTC's `RTCVideoEncoder`.
final class VideoEncoderAdapter: NSObject, LKRTCVideoEncoder, @unchecked Sendable {
    /// Holds the current WebRTC callback so the closure handed to the encoder can
    /// stay the same object across `setCallback` calls, and so clearing it cannot
    /// race with a frame being delivered from an encoder thread.
    private final class CallbackBox: @unchecked Sendable {
        private let lock: some Lock = createLock()
        // WebRTC's encoded image callback is safe to invoke from any thread,
        // and access to the stored block is serialized by the lock.
        private nonisolated(unsafe) var callback: RTCVideoEncoderCallback?
        private var isAttached = false

        /// Stores `callback` and reports whether the encoder still needs to be
        /// handed the forwarding closure.
        func set(_ callback: RTCVideoEncoderCallback?) -> Bool {
            lock.sync {
                self.callback = callback
                guard callback != nil, !isAttached else { return false }
                isAttached = true
                return true
            }
        }

        func clear() {
            lock.sync {
                callback = nil
                isAttached = false
            }
        }

        // The callback runs under the lock so that clear() does not return while a
        // frame is still being delivered. WebRTC never calls back into the encoder
        // from inside this callback, so holding the lock here cannot deadlock.
        func invoke(_ image: LKRTCEncodedImage, _ info: any LKRTCCodecSpecificInfo) -> Bool {
            lock.sync {
                guard let callback else { return false }
                return callback(image, info)
            }
        }
    }

    private let encoder: any VideoEncoder
    private let callbackBox = CallbackBox()

    init(encoder: any VideoEncoder) {
        self.encoder = encoder
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
        encoder.setCallback { frame in
            let (image, info) = frame.toRTCType()
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
