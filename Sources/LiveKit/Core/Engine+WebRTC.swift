/*
 * Copyright 2023 LiveKit
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
import Promises

@_implementationOnly import WebRTC

private extension Array where Element: LK_RTCVideoCodecInfo {

    func rewriteCodecsIfNeeded() -> [LK_RTCVideoCodecInfo] {
        // rewrite H264's profileLevelId to 42e032
        let codecs = map { $0.name == kRTCVideoCodecH264Name ? Engine.h264BaselineLevel5CodecInfo : $0 }
        // logger.log("supportedCodecs: \(codecs.map({ "\($0.name) - \($0.parameters)" }).joined(separator: ", "))", type: Engine.self)
        return codecs
    }
}

private class VideoEncoderFactory: LK_RTCDefaultVideoEncoderFactory {

    override func supportedCodecs() -> [LK_RTCVideoCodecInfo] {
        super.supportedCodecs().rewriteCodecsIfNeeded()
    }
}

private class VideoDecoderFactory: LK_RTCDefaultVideoDecoderFactory {

    override func supportedCodecs() -> [LK_RTCVideoCodecInfo] {
        super.supportedCodecs().rewriteCodecsIfNeeded()
    }
}

private class VideoEncoderFactorySimulcast: LK_RTCVideoEncoderFactorySimulcast {

    override func supportedCodecs() -> [LK_RTCVideoCodecInfo] {
        super.supportedCodecs().rewriteCodecsIfNeeded()
    }
}

internal extension Engine {

    static var bypassVoiceProcessing: Bool = false

    static let h264BaselineLevel5CodecInfo: LK_RTCVideoCodecInfo = {

        // this should never happen
        guard let profileLevelId = LK_RTCH264ProfileLevelId(profile: .constrainedBaseline, level: .level5) else {
            logger.log("failed to generate profileLevelId", .error, type: Engine.self)
            fatalError("failed to generate profileLevelId")
        }

        // create a new H264 codec with new profileLevelId
        return LK_RTCVideoCodecInfo(name: kRTCH264CodecName,
                                    parameters: ["profile-level-id": profileLevelId.hexString,
                                                 "level-asymmetry-allowed": "1",
                                                 "packetization-mode": "1"])
    }()

    // global properties are already lazy

    static private let encoderFactory: LK_RTCVideoEncoderFactory = {
        let encoderFactory = VideoEncoderFactory()
        return VideoEncoderFactorySimulcast(primary: encoderFactory,
                                            fallback: encoderFactory)

    }()

    static private let decoderFactory = VideoDecoderFactory()

    static let audioProcessingModule: LK_RTCDefaultAudioProcessingModule = {
        LK_RTCDefaultAudioProcessingModule()
    }()

    static let peerConnectionFactory: LK_RTCPeerConnectionFactory = {

        logger.log("Initializing SSL...", type: Engine.self)

        RTCInitializeSSL()

        logger.log("Initializing Field trials...", type: Engine.self)

        let fieldTrials = [kRTCFieldTrialUseNWPathMonitor: kRTCFieldTrialEnabledValue]
        RTCInitFieldTrialDictionary(fieldTrials)

        logger.log("Initializing PeerConnectionFactory...", type: Engine.self)

        return LK_RTCPeerConnectionFactory(bypassVoiceProcessing: bypassVoiceProcessing,
                                           encoderFactory: encoderFactory,
                                           decoderFactory: decoderFactory,
                                           audioProcessingModule: audioProcessingModule)
    }()

    // forbid direct access

    static var audioDeviceModule: LK_RTCAudioDeviceModule {
        peerConnectionFactory.audioDeviceModule
    }

    static func createPeerConnection(_ configuration: LK_RTCConfiguration,
                                     constraints: LK_RTCMediaConstraints) -> LK_RTCPeerConnection? {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.peerConnection(with: configuration,
                                                                                constraints: constraints,
                                                                                delegate: nil) }
    }

    static func createVideoSource(forScreenShare: Bool) -> LK_RTCVideoSource {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.videoSource(forScreenCast: forScreenShare) }
    }

    static func createVideoTrack(source: LK_RTCVideoSource) -> LK_RTCVideoTrack {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.videoTrack(with: source,
                                                                            trackId: UUID().uuidString) }
    }

    static func createAudioSource(_ constraints: LK_RTCMediaConstraints?) -> LK_RTCAudioSource {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.audioSource(with: constraints) }
    }

    static func createAudioTrack(source: LK_RTCAudioSource) -> LK_RTCAudioTrack {
        DispatchQueue.liveKitWebRTC.sync { peerConnectionFactory.audioTrack(with: source,
                                                                            trackId: UUID().uuidString) }
    }

    static func createDataChannelConfiguration(ordered: Bool = true,
                                               maxRetransmits: Int32 = -1) -> LK_RTCDataChannelConfiguration {
        let result = DispatchQueue.liveKitWebRTC.sync { LK_RTCDataChannelConfiguration() }
        result.isOrdered = ordered
        result.maxRetransmits = maxRetransmits
        return result
    }

    static func createDataBuffer(data: Data) -> LK_RTCDataBuffer {
        DispatchQueue.liveKitWebRTC.sync { LK_RTCDataBuffer(data: data, isBinary: true) }
    }

    static func createIceCandidate(fromJsonString: String) throws -> LK_RTCIceCandidate {
        try DispatchQueue.liveKitWebRTC.sync { try LK_RTCIceCandidate(fromJsonString: fromJsonString) }
    }

    static func createSessionDescription(type: RTCSdpType, sdp: String) -> LK_RTCSessionDescription {
        DispatchQueue.liveKitWebRTC.sync { LK_RTCSessionDescription(type: type, sdp: sdp) }
    }

    static func createVideoCapturer() -> LK_RTCVideoCapturer {
        DispatchQueue.liveKitWebRTC.sync { LK_RTCVideoCapturer() }
    }

    static func createRtpEncodingParameters(rid: String? = nil,
                                            encoding: MediaEncoding? = nil,
                                            scaleDownBy: Double? = nil,
                                            active: Bool = true) -> LK_RTCRtpEncodingParameters {

        let result = DispatchQueue.liveKitWebRTC.sync { LK_RTCRtpEncodingParameters() }

        result.isActive = active
        result.rid = rid

        if let scaleDownBy = scaleDownBy {
            result.scaleResolutionDownBy = NSNumber(value: scaleDownBy)
        }

        if let encoding = encoding {
            result.maxBitrateBps = NSNumber(value: encoding.maxBitrate)

            // VideoEncoding specific
            if let videoEncoding = encoding as? VideoEncoding {
                result.maxFramerate = NSNumber(value: videoEncoding.maxFps)
            }
        }

        return result
    }
}
