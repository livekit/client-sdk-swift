/*
 * Copyright 2022 LiveKit
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
import WebRTC

extension RTCConfiguration {

    public static let defaultIceServers = ["stun:stun.l.google.com:19302",
                                           "stun:stun1.l.google.com:19302"]

    public static func liveKitDefault() -> RTCConfiguration {

        let result = DispatchQueue.webRTC.sync { RTCConfiguration() }
        result.sdpSemantics = .unifiedPlan
        result.continualGatheringPolicy = .gatherContinually
        result.candidateNetworkPolicy = .all
        result.tcpCandidatePolicy = .enabled
        result.iceTransportPolicy = .all

        result.iceServers = [ DispatchQueue.webRTC.sync { RTCIceServer(urlStrings: defaultIceServers) } ]

        return result
    }

    public convenience init(copy configuration: RTCConfiguration) {
        self.init()
        self.enableDscp = configuration.enableDscp
        self.iceServers = configuration.iceServers
        self.certificate = configuration.certificate
        self.iceTransportPolicy = configuration.iceTransportPolicy
        self.bundlePolicy = configuration.bundlePolicy
        self.rtcpMuxPolicy = configuration.rtcpMuxPolicy
        self.tcpCandidatePolicy = configuration.tcpCandidatePolicy
        self.candidateNetworkPolicy = configuration.candidateNetworkPolicy
        self.continualGatheringPolicy = configuration.continualGatheringPolicy
        self.disableIPV6 = configuration.disableIPV6
        self.disableIPV6OnWiFi = configuration.disableIPV6OnWiFi
        self.maxIPv6Networks = configuration.maxIPv6Networks
        self.disableLinkLocalNetworks = configuration.disableLinkLocalNetworks
        self.audioJitterBufferMaxPackets = configuration.audioJitterBufferMaxPackets
        self.audioJitterBufferFastAccelerate = configuration.audioJitterBufferFastAccelerate
        self.iceConnectionReceivingTimeout = configuration.iceConnectionReceivingTimeout
        self.iceBackupCandidatePairPingInterval = configuration.iceBackupCandidatePairPingInterval
        self.keyType = configuration.keyType
        self.iceCandidatePoolSize = configuration.iceCandidatePoolSize
        self.shouldPruneTurnPorts = configuration.shouldPruneTurnPorts
        self.shouldPresumeWritableWhenFullyRelayed = configuration.shouldPresumeWritableWhenFullyRelayed
        self.shouldSurfaceIceCandidatesOnIceTransportTypeChanged = configuration.shouldSurfaceIceCandidatesOnIceTransportTypeChanged
        self.iceCheckMinInterval = configuration.iceCheckMinInterval
        self.sdpSemantics = configuration.sdpSemantics
        self.activeResetSrtpParams = configuration.activeResetSrtpParams
        self.allowCodecSwitching = configuration.allowCodecSwitching
        self.cryptoOptions = configuration.cryptoOptions
        self.turnLoggingId = configuration.turnLoggingId
        self.rtcpAudioReportIntervalMs = configuration.rtcpAudioReportIntervalMs
        self.rtcpVideoReportIntervalMs = configuration.rtcpVideoReportIntervalMs
        self.enableImplicitRollback = configuration.enableImplicitRollback
        self.offerExtmapAllowMixed = configuration.offerExtmapAllowMixed
        self.iceCheckIntervalStrongConnectivity = configuration.iceCheckIntervalStrongConnectivity
        self.iceCheckIntervalWeakConnectivity = configuration.iceCheckIntervalWeakConnectivity
        self.iceUnwritableTimeout = configuration.iceUnwritableTimeout
        self.iceUnwritableMinChecks = configuration.iceUnwritableMinChecks
        self.iceInactiveTimeout = configuration.iceInactiveTimeout
    }
}
