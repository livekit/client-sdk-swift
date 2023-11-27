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
import WebRTC

public extension RTCConfiguration {
    static func liveKitDefault() -> RTCConfiguration {
        let result = DispatchQueue.liveKitWebRTC.sync { RTCConfiguration() }
        result.sdpSemantics = .unifiedPlan
        result.continualGatheringPolicy = .gatherContinually
        result.candidateNetworkPolicy = .all
        result.tcpCandidatePolicy = .enabled
        result.iceTransportPolicy = .all

        return result
    }

    convenience init(copy configuration: RTCConfiguration) {
        self.init()
        enableDscp = configuration.enableDscp
        iceServers = configuration.iceServers
        certificate = configuration.certificate
        iceTransportPolicy = configuration.iceTransportPolicy
        bundlePolicy = configuration.bundlePolicy
        rtcpMuxPolicy = configuration.rtcpMuxPolicy
        tcpCandidatePolicy = configuration.tcpCandidatePolicy
        candidateNetworkPolicy = configuration.candidateNetworkPolicy
        continualGatheringPolicy = configuration.continualGatheringPolicy
        disableIPV6OnWiFi = configuration.disableIPV6OnWiFi
        maxIPv6Networks = configuration.maxIPv6Networks
        disableLinkLocalNetworks = configuration.disableLinkLocalNetworks
        audioJitterBufferMaxPackets = configuration.audioJitterBufferMaxPackets
        audioJitterBufferFastAccelerate = configuration.audioJitterBufferFastAccelerate
        iceConnectionReceivingTimeout = configuration.iceConnectionReceivingTimeout
        iceBackupCandidatePairPingInterval = configuration.iceBackupCandidatePairPingInterval
        keyType = configuration.keyType
        iceCandidatePoolSize = configuration.iceCandidatePoolSize
        shouldPruneTurnPorts = configuration.shouldPruneTurnPorts
        shouldPresumeWritableWhenFullyRelayed = configuration.shouldPresumeWritableWhenFullyRelayed
        shouldSurfaceIceCandidatesOnIceTransportTypeChanged = configuration.shouldSurfaceIceCandidatesOnIceTransportTypeChanged
        iceCheckMinInterval = configuration.iceCheckMinInterval
        sdpSemantics = configuration.sdpSemantics
        activeResetSrtpParams = configuration.activeResetSrtpParams
        allowCodecSwitching = configuration.allowCodecSwitching
        cryptoOptions = configuration.cryptoOptions
        turnLoggingId = configuration.turnLoggingId
        rtcpAudioReportIntervalMs = configuration.rtcpAudioReportIntervalMs
        rtcpVideoReportIntervalMs = configuration.rtcpVideoReportIntervalMs
        enableImplicitRollback = configuration.enableImplicitRollback
        offerExtmapAllowMixed = configuration.offerExtmapAllowMixed
        iceCheckIntervalStrongConnectivity = configuration.iceCheckIntervalStrongConnectivity
        iceCheckIntervalWeakConnectivity = configuration.iceCheckIntervalWeakConnectivity
        iceUnwritableTimeout = configuration.iceUnwritableTimeout
        iceUnwritableMinChecks = configuration.iceUnwritableMinChecks
        iceInactiveTimeout = configuration.iceInactiveTimeout
    }
}
