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

import Foundation

internal import LiveKitWebRTC

private extension Array where Element: LKRTCVideoCodecInfo {
    func rewriteCodecsIfNeeded() -> [LKRTCVideoCodecInfo] {
        // rewrite H264's profileLevelId to 42e032
        let codecs = map { $0.name == kLKRTCVideoCodecH264Name ? RTC.h264BaselineLevel5CodecInfo : $0 }
        // logger.log("supportedCodecs: \(codecs.map({ "\($0.name) - \($0.parameters)" }).joined(separator: ", "))", type: RTC.self)
        return codecs
    }
}

private class VideoEncoderFactory: LKRTCDefaultVideoEncoderFactory, @unchecked Sendable {
    override func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        super.supportedCodecs().rewriteCodecsIfNeeded()
    }
}

private class VideoDecoderFactory: LKRTCDefaultVideoDecoderFactory, @unchecked Sendable {
    override func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        super.supportedCodecs().rewriteCodecsIfNeeded()
    }
}

private class VideoEncoderFactorySimulcast: LKRTCVideoEncoderFactorySimulcast, @unchecked Sendable {
    override func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        super.supportedCodecs().rewriteCodecsIfNeeded()
    }
}

actor RTC {
    struct PeerConnectionFactoryState {
        var isInitialized: Bool = false
        var admType: AudioDeviceModuleType = .audioEngine
        var bypassVoiceProcessing: Bool = false
    }

    static let pcFactoryState = StateSync(PeerConnectionFactoryState())

    static let h264BaselineLevel5CodecInfo: LKRTCVideoCodecInfo = {
        // this should never happen
        guard let profileLevelId = LKRTCH264ProfileLevelId(profile: .constrainedBaseline, level: .level5) else {
            logger.log("failed to generate profileLevelId", .error, type: Room.self)
            fatalError("failed to generate profileLevelId")
        }

        // create a new H264 codec with new profileLevelId
        return LKRTCVideoCodecInfo(name: kLKRTCH264CodecName,
                                   parameters: ["profile-level-id": profileLevelId.hexString,
                                                "level-asymmetry-allowed": "1",
                                                "packetization-mode": "1"])
    }()

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

        logger.log("Initializing SSL...", type: Room.self)

        LKRTCInitializeSSL()

        logger.log("Initializing PeerConnectionFactory...", type: Room.self)

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

    static func createPeerConnection(_ configuration: LKRTCConfiguration,
                                     constraints: LKRTCMediaConstraints) -> LKRTCPeerConnection?
    {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.peerConnection(with: configuration,
                                                                                constraints: constraints,
                                                                                delegate: nil) }
    }

    static func createVideoSource(forScreenShare: Bool) -> LKRTCVideoSource {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.videoSource(forScreenCast: forScreenShare) }
    }

    static func createVideoTrack(source: LKRTCVideoSource) -> LKRTCVideoTrack {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.videoTrack(with: source,
                                                                            trackId: UUID().uuidString) }
    }

    static func createAudioSource(_ constraints: LKRTCMediaConstraints?) -> LKRTCAudioSource {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.audioSource(with: constraints) }
    }

    static func createAudioTrack(source: LKRTCAudioSource) -> LKRTCAudioTrack {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.audioTrack(with: source,
                                                                            trackId: UUID().uuidString) }
    }

    static func createDataChannelConfiguration(ordered: Bool = true,
                                               maxRetransmits: Int32 = -1) -> LKRTCDataChannelConfiguration
    {
        let result = DispatchQueue.liveKitWebRTC.sync { LKRTCDataChannelConfiguration() }
        result.isOrdered = ordered
        result.maxRetransmits = maxRetransmits
        return result
    }

    static func createDataBuffer(data: Data) -> LKRTCDataBuffer {
        DispatchQueue.liveKitWebRTC.sync { LKRTCDataBuffer(data: data, isBinary: true) }
    }

    static func createIceCandidate(fromJsonString: String) throws -> LKRTCIceCandidate {
        try DispatchQueue.liveKitWebRTC.sync { try LKRTCIceCandidate(fromJsonString: fromJsonString) }
    }

    static func createSessionDescription(type: LKRTCSdpType, sdp: String) -> LKRTCSessionDescription {
        DispatchQueue.liveKitWebRTC.sync { LKRTCSessionDescription(type: type, sdp: sdp) }
    }

    static func createVideoCapturer() -> LKRTCVideoCapturer {
        DispatchQueue.liveKitWebRTC.sync { LKRTCVideoCapturer() }
    }

    static func createRtpEncodingParameters(rid: String? = nil,
                                            encoding: MediaEncoding? = nil,
                                            scaleDownBy: Double? = nil,
                                            active: Bool = true,
                                            scalabilityMode: ScalabilityMode? = nil) -> LKRTCRtpEncodingParameters
    {
        let result = DispatchQueue.liveKitWebRTC.sync { LKRTCRtpEncodingParameters() }

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

        return result
    }
}
