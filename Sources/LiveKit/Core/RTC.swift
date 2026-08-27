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

private final class VideoEncoderFactory: LKRTCDefaultVideoEncoderFactory, @unchecked Sendable {}

private final class VideoDecoderFactory: LKRTCDefaultVideoDecoderFactory, @unchecked Sendable {}

private final class VideoEncoderFactorySimulcast: LKRTCVideoEncoderFactorySimulcast, @unchecked Sendable {}

/// The SDK's WebRTC isolation domain, executed on its own dispatch queue.
///
/// libwebrtc's API objects are proxies: every call, and the release of the last reference, is a
/// `BlockingCall` that waits on WebRTC's signaling or worker thread. Those threads can stall, and
/// Swift Concurrency's cooperative pool does not grow when a thread blocks, so such calls never run
/// on it. Code isolated to `@RTC` runs on a dispatch thread that is allowed to block; async callers
/// hop in with ``run(_:)``, public synchronous APIs with ``blocking(_:)``.
///
/// The data-channel send path (`sendData`, `readyState`, `LKRTCDataBuffer`) stays `nonisolated` on
/// purpose: it is per-packet and latency-sensitive, and `sendData` blocks only on the network thread.
@globalActor
actor RTC {
    static let shared = RTC()

    static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "LiveKitSDK.webRTC", qos: .default)
        queue.setSpecific(key: queueKey, value: true)
        return queue
    }()

    private static let queueKey = DispatchSpecificKey<Bool>()
    private static let executor = DispatchQueueExecutor(queue: queue)

    static var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) == true
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self.executor.asUnownedSerialExecutor()
    }

    /// Runs `body` on the RTC executor; the calling task suspends instead of blocking a
    /// cooperative-pool thread while the WebRTC calls inside wait on libwebrtc.
    static func run<T: Sendable>(_ body: @RTC @Sendable () throws -> T) async rethrows -> T {
        try await body()
    }

    /// Runs `body` on the RTC executor from synchronous code, blocking the caller until it
    /// completes. For public synchronous APIs only; async code uses ``run(_:)``.
    static func blocking<T>(_ body: () throws -> T) rethrows -> T {
        if isOnQueue { return try body() }
        return try queue.sync(execute: body)
    }

    struct PeerConnectionFactoryState {
        var isInitialized: Bool = false
        var admType: AudioDeviceModuleType = .audioEngine
        var bypassVoiceProcessing: Bool = false
    }

    static let pcFactoryState = StateSync(PeerConnectionFactoryState())

    // global properties are already lazy

    static let encoderFactory: LKRTCVideoEncoderFactory & Sendable = {
        let encoderFactory = VideoEncoderFactory()
        return VideoEncoderFactorySimulcast(primary: encoderFactory,
                                            fallback: encoderFactory)

    }()

    static let decoderFactory: LKRTCVideoDecoderFactory & Sendable = VideoDecoderFactory()

    static let audioProcessingModule: LKRTCDefaultAudioProcessingModule = .init()

    static let videoSenderCapabilities = peerConnectionFactory.rtpSenderCapabilities(forKind: kLKRTCMediaStreamTrackKindVideo)
    static let audioSenderCapabilities = peerConnectionFactory.rtpSenderCapabilities(forKind: kLKRTCMediaStreamTrackKindAudio)

    static let peerConnectionFactory: LKRTCPeerConnectionFactory = {
        // Update pc init lock
        let (admType, bypassVoiceProcessing) = pcFactoryState.mutate {
            $0.isInitialized = true
            return ($0.admType, $0.bypassVoiceProcessing)
        }

        Room.log("Initializing SSL...")

        LKRTCInitializeSSL()

        Room.log("Initializing PeerConnectionFactory...")

        return LKRTCPeerConnectionFactory(audioDeviceModuleType: admType.toRTCType(),
                                          bypassVoiceProcessing: bypassVoiceProcessing,
                                          encoderFactory: encoderFactory,
                                          decoderFactory: decoderFactory,
                                          audioProcessingModule: audioProcessingModule)
    }()

    // forbid direct access

    static var audioDeviceModule: LKRTCAudioDeviceModule {
        peerConnectionFactory.audioDeviceModule
    }

    // MARK: - Factory (libwebrtc proxies: each call blocks on the signaling thread)

    static func createPeerConnection(_ configuration: LKRTCConfiguration,
                                     constraints: LKRTCMediaConstraints) -> LKRTCPeerConnection?
    {
        blocking { peerConnectionFactory.peerConnection(with: configuration,
                                                        constraints: constraints,
                                                        delegate: nil) }
    }

    static func createVideoSource(forScreenShare: Bool) -> LKRTCVideoSource {
        blocking { peerConnectionFactory.videoSource(forScreenCast: forScreenShare) }
    }

    static func createVideoTrack(source: LKRTCVideoSource) -> LKRTCVideoTrack {
        blocking { peerConnectionFactory.videoTrack(with: source, trackId: UUID().uuidString) }
    }

    static func createAudioSource(_ constraints: LKRTCMediaConstraints?) -> LKRTCAudioSource {
        blocking { peerConnectionFactory.audioSource(with: constraints) }
    }

    static func createAudioTrack(source: LKRTCAudioSource) -> LKRTCAudioTrack {
        blocking { peerConnectionFactory.audioTrack(with: source, trackId: UUID().uuidString) }
    }

    // Marshalled to the worker thread inside webrtc-sdk, safe to call directly.
    static func audioProcessingState() -> LKRTCAudioProcessingState {
        peerConnectionFactory.audioProcessingState
    }

    // MARK: - Value objects

    // Plain Objective-C objects with no libwebrtc proxy behind them: nothing to wait on, so they
    // are built directly wherever they are needed.

    static func createDataChannelConfiguration(ordered: Bool = true,
                                               maxRetransmits: Int32 = -1) -> LKRTCDataChannelConfiguration
    {
        let result = LKRTCDataChannelConfiguration()
        result.isOrdered = ordered
        result.maxRetransmits = maxRetransmits
        return result
    }

    static func createDataBuffer(data: Data) -> LKRTCDataBuffer {
        LKRTCDataBuffer(data: data, isBinary: true)
    }

    static func createIceCandidate(fromJsonString: String) throws -> LKRTCIceCandidate {
        try LKRTCIceCandidate(fromJsonString: fromJsonString)
    }

    static func createSessionDescription(type: LKRTCSdpType, sdp: String) -> LKRTCSessionDescription {
        LKRTCSessionDescription(type: type, sdp: sdp)
    }

    static func createVideoCapturer() -> LKRTCVideoCapturer {
        LKRTCVideoCapturer()
    }

    static func createRtpEncodingParameters(rid: String? = nil,
                                            encoding: MediaEncoding? = nil,
                                            scaleDownBy: Double? = nil,
                                            active: Bool = true,
                                            scalabilityMode: ScalabilityMode? = nil) -> LKRTCRtpEncodingParameters
    {
        let result = LKRTCRtpEncodingParameters()

        result.isActive = active
        result.rid = rid

        if let scaleDownBy {
            result.scaleResolutionDownBy = NSNumber(value: scaleDownBy)
        }

        if let encoding {
            result.maxBitrateBps = NSNumber(value: encoding.maxBitrate)

            // VideoEncoding specific
            if let videoEncoding = encoding as? VideoEncoding {
                result.maxFramerate = NSNumber(value: videoEncoding.maxFps)
            }
        }

        if let scalabilityMode {
            result.scalabilityMode = scalabilityMode.rawStringValue
        }

        if let bitratePriority = encoding?.bitratePriority {
            result.bitratePriority = bitratePriority.toBitratePriority()
        }

        if let networkPriority = encoding?.networkPriority {
            result.networkPriority = networkPriority.toRTCPriority()
        }

        return result
    }
}
