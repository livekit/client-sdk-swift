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

/// Stats spec defined at https://www.w3.org/TR/webrtc-stats/

public enum StatisticsType: String, Sendable {
    case codec
    case inboundRtp = "inbound-rtp"
    case outboundRtp = "outbound-rtp"
    case remoteInboundRtp = "remote-inbound-rtp"
    case remoteOutboundRtp = "remote-outbound-rtp"
    case mediaSource = "media-source"
    case mediaPlayout = "media-playout"
    case peerConnection = "peer-connection"
    case dataChannel = "data-channel"
    case transport
    case candidatePair = "candidate-pair"
    case localCandidate = "local-candidate"
    case remoteCandidate = "remote-candidate"
    case certificate
}

public enum QualityLimitationReason: String, Sendable {
    case none
    case cpu
    case bandwidth
    case other
}

public enum DtlsRole: String, Sendable {
    case client
    case server
    case unknown
}

public enum IceCandidatePairState: String, Sendable {
    case frozen
    case waiting
    case inProgress = "in-progress"
    case failed
    case succeeded
}

public enum DataChannelState: String, Sendable {
    case connecting
    case open
    case closing
    case closed
}

public enum IceRole: String, Sendable {
    case unknown
    case controlling
    case controlled
}

public enum DtlsTransportState: String, Sendable {
    case new
    case connecting
    case connected
    case closed
    case failed
}

public enum IceTransportState: String, Sendable {
    case new
    case checking
    case connected
    case completed
    case disconnected
    case failed
    case closed
}

public enum IceCandidateType: String, Sendable {
    case host
    case srflx
    case prflx
    case relay
}

public enum IceServerTransportProtocol: String, Sendable {
    case udp
    case tcp
    case tls
}

public enum IceTcpCandidateType: String, Sendable {
    case active
    case passive
    case so
}

// Base class
@objc
public class Statistics: NSObject, Identifiable {
    public let id: String
    public let type: StatisticsType
    public let timestamp: Double

    init?(id: String,
          type: StatisticsType,
          timestamp: Double)
    {
        self.id = id
        self.type = type
        self.timestamp = timestamp
    }
}

// type: codec
@objc
public class CodecStatistics: Statistics {
    public let payloadType: UInt?
    public let transportId: String?
    public let mimeType: String?
    public let clockRate: UInt?
    public let channels: UInt?
    public let sdpFmtpLine: String?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject])
    {
        payloadType = rawValues.readOptional("payloadType")
        transportId = rawValues.readOptional("transportId")
        mimeType = rawValues.readOptional("mimeType")
        clockRate = rawValues.readOptional("clockRate")
        channels = rawValues.readOptional("channels")
        sdpFmtpLine = rawValues.readOptional("sdpFmtpLine")

        super.init(id: id,
                   type: .codec,
                   timestamp: timestamp)
    }
}

@objc
public class MediaSourceStatistics: Statistics {
    public let trackIdentifier: String?
    public let kind: String?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject])
    {
        trackIdentifier = rawValues.readOptional("trackIdentifier")
        kind = rawValues.readOptional("kind")

        super.init(id: id,
                   type: .mediaSource,
                   timestamp: timestamp)
    }
}

@objc
public class RtpStreamStatistics: Statistics {
    public let ssrc: UInt?
    public let kind: String?
    public let transportId: String?
    public let codecId: String?

    init?(id: String,
          type: StatisticsType,
          timestamp: Double,
          rawValues: [String: NSObject])
    {
        ssrc = rawValues.readOptional("ssrc")
        kind = rawValues.readOptional("kind")
        transportId = rawValues.readOptional("transportId")
        codecId = rawValues.readOptional("codecId")

        super.init(id: id,
                   type: type,
                   timestamp: timestamp)
    }
}

// type: media-playout
@objc
public class AudioPlayoutStatistics: Statistics {
    public let kind: String?
    public let synthesizedSamplesDuration: Double?
    public let synthesizedSamplesEvents: UInt?
    public let totalSamplesDuration: Double?
    public let totalPlayoutDelay: Double?
    public let totalSamplesCount: UInt64?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject])
    {
        kind = rawValues.readOptional("kind")
        synthesizedSamplesDuration = rawValues.readOptional("synthesizedSamplesDuration")
        synthesizedSamplesEvents = rawValues.readOptional("synthesizedSamplesEvents")
        totalSamplesDuration = rawValues.readOptional("totalSamplesDuration")
        totalPlayoutDelay = rawValues.readOptional("totalPlayoutDelay")
        totalSamplesCount = rawValues.readOptional("totalSamplesCount")

        super.init(id: id,
                   type: .mediaPlayout,
                   timestamp: timestamp)
    }
}

// type: peer-connection
@objc
public class PeerConnectionStatistics: Statistics {
    public let dataChannelsOpened: UInt?
    public let dataChannelsClosed: UInt?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject])
    {
        dataChannelsOpened = rawValues.readOptional("dataChannelsOpened")
        dataChannelsClosed = rawValues.readOptional("dataChannelsClosed")

        super.init(id: id,
                   type: .peerConnection,
                   timestamp: timestamp)
    }
}

// type: data-channel
@objc
public class DataChannelStatistics: Statistics {
    public let label: String?
    public let `protocol`: String?
    public let dataChannelIdentifier: UInt16?
    public let state: DataChannelState?
    public let messagesSent: UInt?
    public let bytesSent: UInt64?
    public let messagesReceived: UInt?
    public let bytesReceived: UInt64?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject])
    {
        label = rawValues.readOptional("label")
        `protocol` = rawValues.readOptional("protocol")
        dataChannelIdentifier = rawValues.readOptional("dataChannelIdentifier")
        state = DataChannelState(rawValue: rawValues.readNonOptional("state"))
        messagesSent = rawValues.readOptional("messagesSent")
        bytesSent = rawValues.readOptional("bytesSent")
        messagesReceived = rawValues.readOptional("messagesReceived")
        bytesReceived = rawValues.readOptional("bytesReceived")

        super.init(id: id,
                   type: .dataChannel,
                   timestamp: timestamp)
    }
}

// type: transport
@objc
public class TransportStatistics: Statistics {
    public let packetsSent: UInt64?
    public let packetsReceived: UInt64?
    public let bytesSent: UInt64?
    public let bytesReceived: UInt64?
    public let iceRole: IceRole?
    public let iceLocalUsernameFragment: String?
    public let dtlsState: DtlsTransportState?
    public let iceState: IceTransportState?
    public let selectedCandidatePairId: String?
    public let localCertificateId: String?
    public let remoteCertificateId: String?
    public let tlsVersion: String?
    public let dtlsCipher: String?
    public let dtlsRole: DtlsRole?
    public let srtpCipher: String?
    public let selectedCandidatePairChanges: UInt?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject])
    {
        packetsSent = rawValues.readOptional("packetsSent")
        packetsReceived = rawValues.readOptional("packetsReceived")
        bytesSent = rawValues.readOptional("bytesSent")
        bytesReceived = rawValues.readOptional("bytesReceived")
        iceRole = IceRole(rawValue: rawValues.readNonOptional("iceRole"))
        iceLocalUsernameFragment = rawValues.readOptional("iceLocalUsernameFragment")
        dtlsState = DtlsTransportState(rawValue: rawValues.readNonOptional("dtlsState"))
        iceState = IceTransportState(rawValue: rawValues.readNonOptional("iceState"))
        selectedCandidatePairId = rawValues.readOptional("selectedCandidatePairId")
        localCertificateId = rawValues.readOptional("localCertificateId")
        remoteCertificateId = rawValues.readOptional("remoteCertificateId")
        tlsVersion = rawValues.readOptional("tlsVersion")
        dtlsCipher = rawValues.readOptional("dtlsCipher")
        dtlsRole = DtlsRole(rawValue: rawValues.readNonOptional("dtlsRole"))
        srtpCipher = rawValues.readOptional("srtpCipher")
        selectedCandidatePairChanges = rawValues.readOptional("selectedCandidatePairChanges")

        super.init(id: id,
                   type: .transport,
                   timestamp: timestamp)
    }
}

// type: local-candidate, remote-candidate
@objc
public class IceCandidateStatistics: Statistics {
    public let transportId: String?
    public let address: String?
    public let port: Int?
    public let `protocol`: String?
    public let candidateType: IceCandidateType?
    public let priority: Int?
    public let url: String?
    public let relayProtocol: IceServerTransportProtocol?
    public let foundation: String?
    public let relatedAddress: String?
    public let relatedPort: Int?
    public let usernameFragment: String?
    public let tcpType: IceTcpCandidateType?

    init?(id: String,
          type: StatisticsType,
          timestamp: Double,
          rawValues: [String: NSObject])
    {
        transportId = rawValues.readOptional("transportId")
        address = rawValues.readOptional("address")
        port = rawValues.readOptional("port")
        `protocol` = rawValues.readOptional("protocol")
        candidateType = IceCandidateType(rawValue: rawValues.readNonOptional("candidateType"))
        priority = rawValues.readOptional("priority")
        url = rawValues.readOptional("url")
        relayProtocol = IceServerTransportProtocol(rawValue: rawValues.readNonOptional("relayProtocol"))
        foundation = rawValues.readOptional("foundation")
        relatedAddress = rawValues.readOptional("relatedAddress")
        relatedPort = rawValues.readOptional("relatedPort")
        usernameFragment = rawValues.readOptional("usernameFragment")
        tcpType = IceTcpCandidateType(rawValue: rawValues.readNonOptional("tcpType"))

        super.init(id: id,
                   type: type,
                   timestamp: timestamp)
    }
}

@objc
public class LocalIceCandidateStatistics: IceCandidateStatistics {
    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject])
    {
        super.init(id: id,
                   type: .localCandidate,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

@objc
public class RemoteIceCandidateStatistics: IceCandidateStatistics {
    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject])
    {
        super.init(id: id,
                   type: .remoteCandidate,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

// type: candidate-pair
@objc
public class IceCandidatePairStatistics: Statistics {
    public let transportId: String?
    public let localCandidateId: String?
    public let remoteCandidateId: String?
    public let state: IceCandidatePairState?
    public let nominated: Bool?
    public let packetsSent: UInt64?
    public let packetsReceived: UInt64?
    public let bytesSent: UInt64?
    public let bytesReceived: UInt64?
    public let lastPacketSentTimestamp: Double?
    public let lastPacketReceivedTimestamp: Double?
    public let totalRoundTripTime: Double?
    public let currentRoundTripTime: Double?
    public let availableOutgoingBitrate: Double?
    public let availableIncomingBitrate: Double?
    public let requestsReceived: UInt64?
    public let requestsSent: UInt64?
    public let responsesReceived: UInt64?
    public let responsesSent: UInt64?
    public let consentRequestsSent: UInt64?
    public let packetsDiscardedOnSend: UInt?
    public let bytesDiscardedOnSend: UInt64?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject])
    {
        transportId = rawValues.readOptional("transportId")
        localCandidateId = rawValues.readOptional("localCandidateId")
        remoteCandidateId = rawValues.readOptional("remoteCandidateId")
        state = IceCandidatePairState(rawValue: rawValues.readNonOptional("state"))
        nominated = rawValues.readOptional("nominated")
        packetsSent = rawValues.readOptional("packetsSent")
        packetsReceived = rawValues.readOptional("packetsReceived")
        bytesSent = rawValues.readOptional("bytesSent")
        bytesReceived = rawValues.readOptional("bytesReceived")
        lastPacketSentTimestamp = rawValues.readOptional("lastPacketSentTimestamp")
        lastPacketReceivedTimestamp = rawValues.readOptional("lastPacketReceivedTimestamp")
        totalRoundTripTime = rawValues.readOptional("totalRoundTripTime")
        currentRoundTripTime = rawValues.readOptional("currentRoundTripTime")
        availableOutgoingBitrate = rawValues.readOptional("availableOutgoingBitrate")
        availableIncomingBitrate = rawValues.readOptional("availableIncomingBitrate")
        requestsReceived = rawValues.readOptional("requestsReceived")
        requestsSent = rawValues.readOptional("requestsSent")
        responsesReceived = rawValues.readOptional("responsesReceived")
        responsesSent = rawValues.readOptional("responsesSent")
        consentRequestsSent = rawValues.readOptional("consentRequestsSent")
        packetsDiscardedOnSend = rawValues.readOptional("packetsDiscardedOnSend")
        bytesDiscardedOnSend = rawValues.readOptional("bytesDiscardedOnSend")

        super.init(id: id,
                   type: .candidatePair,
                   timestamp: timestamp)
    }
}

// type: certificate
@objc
public class CertificateStatistics: Statistics {
    public let fingerprint: String?
    public let fingerprintAlgorithm: String?
    public let base64Certificate: String?
    public let issuerCertificateId: String?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject])
    {
        fingerprint = rawValues.readOptional("fingerprint")
        fingerprintAlgorithm = rawValues.readOptional("fingerprintAlgorithm")
        base64Certificate = rawValues.readOptional("base64Certificate")
        issuerCertificateId = rawValues.readOptional("issuerCertificateId")

        super.init(id: id,
                   type: .certificate,
                   timestamp: timestamp)
    }
}

@objc
public class ReceivedRtpStreamStatistics: RtpStreamStatistics {
    public let packetsReceived: UInt64?
    public let packetsLost: Int64?
    public let jitter: Double?

    override init?(id: String,
                   type: StatisticsType,
                   timestamp: Double,
                   rawValues: [String: NSObject])
    {
        packetsReceived = rawValues.readOptional("packetsReceived")
        packetsLost = rawValues.readOptional("packetsLost")
        jitter = rawValues.readOptional("jitter")

        super.init(id: id,
                   type: type,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

@objc
public class SentRtpStreamStatistics: RtpStreamStatistics {
    public let packetsSent: UInt64?
    public let bytesSent: UInt64?

    override init?(id: String,
                   type: StatisticsType,
                   timestamp: Double,
                   rawValues: [String: NSObject])
    {
        packetsSent = rawValues.readOptional("packetsSent")
        bytesSent = rawValues.readOptional("bytesSent")

        super.init(id: id,
                   type: type,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

// type: inbound-rtp
@objc
public class InboundRtpStreamStatistics: ReceivedRtpStreamStatistics {
    public let trackIdentifier: String?
    // let kind: String
    public let mid: String?
    public let remoteId: String?
    public let framesDecoded: UInt?
    public let keyFramesDecoded: UInt?
    public let framesRendered: UInt?
    public let framesDropped: UInt?
    public let frameWidth: UInt?
    public let frameHeight: UInt?
    public let framesPerSecond: Double?
    public let qpSum: UInt64?
    public let totalDecodeTime: Double?
    public let totalInterFrameDelay: Double?
    public let totalSquaredInterFrameDelay: Double?
    public let pauseCount: UInt?
    public let totalPausesDuration: Double?
    public let freezeCount: UInt?
    public let totalFreezesDuration: Double?
    public let lastPacketReceivedTimestamp: Double?
    public let headerBytesReceived: UInt64?
    public let packetsDiscarded: UInt64?
    public let fecPacketsReceived: UInt64?
    public let fecPacketsDiscarded: UInt64?
    public let bytesReceived: UInt64?
    public let nackCount: UInt?
    public let firCount: UInt?
    public let pliCount: UInt?
    public let totalProcessingDelay: Double?
    public let estimatedPlayoutTimestamp: Double?
    public let jitterBufferDelay: Double?
    public let jitterBufferTargetDelay: Double?
    public let jitterBufferEmittedCount: UInt64?
    public let jitterBufferMinimumDelay: Double?
    public let totalSamplesReceived: UInt64?
    public let concealedSamples: UInt64?
    public let silentConcealedSamples: UInt64?
    public let concealmentEvents: UInt64?
    public let insertedSamplesForDeceleration: UInt64?
    public let removedSamplesForAcceleration: UInt64?
    public let audioLevel: Double?
    public let totalAudioEnergy: Double?
    public let totalSamplesDuration: Double?
    public let framesReceived: UInt?
    public let decoderImplementation: String?
    public let playoutId: String?
    public let powerEfficientDecoder: Bool?
    public let framesAssembledFromMultiplePackets: UInt?
    public let totalAssemblyTime: Double?
    public let retransmittedPacketsReceived: UInt64?
    public let retransmittedBytesReceived: UInt64?

    // Weak reference to previous stat so we can compare later.
    public weak var previous: InboundRtpStreamStatistics?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject],
          previous: InboundRtpStreamStatistics?)
    {
        trackIdentifier = rawValues.readOptional("trackIdentifier")
        // self.kind = kind
        mid = rawValues.readOptional("mid")
        remoteId = rawValues.readOptional("remoteId")
        framesDecoded = rawValues.readOptional("framesDecoded")
        keyFramesDecoded = rawValues.readOptional("keyFramesDecoded")
        framesRendered = rawValues.readOptional("framesRendered")
        framesDropped = rawValues.readOptional("framesDropped")
        frameWidth = rawValues.readOptional("frameWidth")
        frameHeight = rawValues.readOptional("frameHeight")
        framesPerSecond = rawValues.readOptional("framesPerSecond")
        qpSum = rawValues.readOptional("qpSum")
        totalDecodeTime = rawValues.readOptional("totalDecodeTime")
        totalInterFrameDelay = rawValues.readOptional("totalInterFrameDelay")
        totalSquaredInterFrameDelay = rawValues.readOptional("totalSquaredInterFrameDelay")
        pauseCount = rawValues.readOptional("pauseCount")
        totalPausesDuration = rawValues.readOptional("totalPausesDuration")
        freezeCount = rawValues.readOptional("freezeCount")
        totalFreezesDuration = rawValues.readOptional("totalFreezesDuration")
        lastPacketReceivedTimestamp = rawValues.readOptional("lastPacketReceivedTimestamp")
        headerBytesReceived = rawValues.readOptional("headerBytesReceived")
        packetsDiscarded = rawValues.readOptional("packetsDiscarded")
        fecPacketsReceived = rawValues.readOptional("fecPacketsReceived")
        fecPacketsDiscarded = rawValues.readOptional("fecPacketsDiscarded")
        bytesReceived = rawValues.readOptional("bytesReceived")
        nackCount = rawValues.readOptional("nackCount")
        firCount = rawValues.readOptional("firCount")
        pliCount = rawValues.readOptional("pliCount")
        totalProcessingDelay = rawValues.readOptional("totalProcessingDelay")
        estimatedPlayoutTimestamp = rawValues.readOptional("estimatedPlayoutTimestamp")
        jitterBufferDelay = rawValues.readOptional("jitterBufferDelay")
        jitterBufferTargetDelay = rawValues.readOptional("jitterBufferTargetDelay")
        jitterBufferEmittedCount = rawValues.readOptional("jitterBufferEmittedCount")
        jitterBufferMinimumDelay = rawValues.readOptional("jitterBufferMinimumDelay")
        totalSamplesReceived = rawValues.readOptional("totalSamplesReceived")
        concealedSamples = rawValues.readOptional("concealedSamples")
        silentConcealedSamples = rawValues.readOptional("silentConcealedSamples")
        concealmentEvents = rawValues.readOptional("concealmentEvents")
        insertedSamplesForDeceleration = rawValues.readOptional("insertedSamplesForDeceleration")
        removedSamplesForAcceleration = rawValues.readOptional("removedSamplesForAcceleration")
        audioLevel = rawValues.readOptional("audioLevel")
        totalAudioEnergy = rawValues.readOptional("totalAudioEnergy")
        totalSamplesDuration = rawValues.readOptional("totalSamplesDuration")
        framesReceived = rawValues.readOptional("framesReceived")
        decoderImplementation = rawValues.readOptional("decoderImplementation")
        playoutId = rawValues.readOptional("playoutId")
        powerEfficientDecoder = rawValues.readOptional("powerEfficientDecoder")
        framesAssembledFromMultiplePackets = rawValues.readOptional("framesAssembledFromMultiplePackets")
        totalAssemblyTime = rawValues.readOptional("totalAssemblyTime")
        retransmittedPacketsReceived = rawValues.readOptional("retransmittedPacketsReceived")
        retransmittedBytesReceived = rawValues.readOptional("retransmittedBytesReceived")

        self.previous = previous

        super.init(id: id,
                   type: .inboundRtp,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

// type: remote-inbound-rtp
@objc
public class RemoteInboundRtpStreamStatistics: ReceivedRtpStreamStatistics {
    public let localId: String?
    public let roundTripTime: Double?
    public let totalRoundTripTime: Double?
    public let fractionLost: Double?
    public let roundTripTimeMeasurements: UInt64?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject])
    {
        localId = rawValues.readOptional("localId")
        roundTripTime = rawValues.readOptional("roundTripTime")
        totalRoundTripTime = rawValues.readOptional("totalRoundTripTime")
        fractionLost = rawValues.readOptional("fractionLost")
        roundTripTimeMeasurements = rawValues.readOptional("roundTripTimeMeasurements")

        super.init(id: id,
                   type: .remoteInboundRtp,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

// type: outbound-rtp
@objc
public class OutboundRtpStreamStatistics: SentRtpStreamStatistics {
    public class QualityLimitationDurations {
        public let none: Double?
        public let cpu: Double?
        public let bandwidth: Double?
        public let other: Double?

        init?(rawValues: [String: NSObject]) {
            none = rawValues.readOptional("none")
            cpu = rawValues.readOptional("cpu")
            bandwidth = rawValues.readOptional("bandwidth")
            other = rawValues.readOptional("other")

            if none == nil, cpu == nil, bandwidth == nil, other == nil {
                return nil
            }
        }
    }

    public let mid: String?
    public let mediaSourceId: String?
    public let remoteId: String?
    public let rid: String?
    public let headerBytesSent: UInt64?
    public let retransmittedPacketsSent: UInt64?
    public let retransmittedBytesSent: UInt64?
    public let targetBitrate: Double?
    public let totalEncodedBytesTarget: UInt64?
    public let frameWidth: UInt?
    public let frameHeight: UInt?
    public let framesPerSecond: Double?
    public let framesSent: UInt?
    public let hugeFramesSent: UInt?
    public let framesEncoded: UInt?
    public let keyFramesEncoded: UInt?
    public let qpSum: UInt64?
    public let totalEncodeTime: Double?
    public let totalPacketSendDelay: Double?
    public let qualityLimitationReason: QualityLimitationReason?
    public let qualityLimitationDurations: QualityLimitationDurations?
    public let qualityLimitationResolutionChanges: UInt?
    public let nackCount: UInt?
    public let firCount: UInt?
    public let pliCount: UInt?
    public let encoderImplementation: String?
    public let powerEfficientEncoder: Bool?
    public let active: Bool?
    public let scalabilityMode: String?

    // Weak reference to previous stat so we can compare later.
    public weak var previous: OutboundRtpStreamStatistics?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject],
          previous: OutboundRtpStreamStatistics?)
    {
        mid = rawValues.readOptional("mid")
        mediaSourceId = rawValues.readOptional("mediaSourceId")
        remoteId = rawValues.readOptional("remoteId")
        rid = rawValues.readOptional("rid")
        headerBytesSent = rawValues.readOptional("headerBytesSent")
        retransmittedPacketsSent = rawValues.readOptional("retransmittedPacketsSent")
        retransmittedBytesSent = rawValues.readOptional("retransmittedBytesSent")
        targetBitrate = rawValues.readOptional("targetBitrate")
        totalEncodedBytesTarget = rawValues.readOptional("totalEncodedBytesTarget")
        frameWidth = rawValues.readOptional("frameWidth")
        frameHeight = rawValues.readOptional("frameHeight")
        framesPerSecond = rawValues.readOptional("framesPerSecond")
        framesSent = rawValues.readOptional("framesSent")
        hugeFramesSent = rawValues.readOptional("hugeFramesSent")
        framesEncoded = rawValues.readOptional("framesEncoded")
        keyFramesEncoded = rawValues.readOptional("keyFramesEncoded")
        qpSum = rawValues.readOptional("qpSum")
        totalEncodeTime = rawValues.readOptional("totalEncodeTime")
        totalPacketSendDelay = rawValues.readOptional("totalPacketSendDelay")
        qualityLimitationReason = QualityLimitationReason(rawValue: rawValues.readNonOptional("qualityLimitationReason"))
        qualityLimitationDurations = QualityLimitationDurations(rawValues: rawValues.readNonOptional("qualityLimitationDurations"))
        qualityLimitationResolutionChanges = rawValues.readOptional("qualityLimitationResolutionChanges")
        nackCount = rawValues.readOptional("nackCount")
        firCount = rawValues.readOptional("firCount")
        pliCount = rawValues.readOptional("pliCount")
        encoderImplementation = rawValues.readOptional("encoderImplementation")
        powerEfficientEncoder = rawValues.readOptional("powerEfficientEncoder")
        active = rawValues.readOptional("active")
        scalabilityMode = rawValues.readOptional("scalabilityMode")

        self.previous = previous

        super.init(id: id,
                   type: .outboundRtp,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

// type: remote-outbound-rtp
@objc
public class RemoteOutboundRtpStreamStatistics: SentRtpStreamStatistics {
    public let localId: String?
    public let remoteTimestamp: Double?
    public let reportsSent: UInt64?
    public let roundTripTime: Double?
    public let totalRoundTripTime: Double?
    public let roundTripTimeMeasurements: UInt64?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject])
    {
        localId = rawValues.readOptional("localId")
        remoteTimestamp = rawValues.readOptional("remoteTimestamp")
        reportsSent = rawValues.readOptional("reportsSent")
        roundTripTime = rawValues.readOptional("roundTripTime")
        totalRoundTripTime = rawValues.readOptional("totalRoundTripTime")
        roundTripTimeMeasurements = rawValues.readOptional("roundTripTimeMeasurements")

        super.init(id: id,
                   type: .remoteOutboundRtp,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

@objc
public class AudioSourceStatistics: MediaSourceStatistics {
    public let audioLevel: Double?
    public let totalAudioEnergy: Double?
    public let totalSamplesDuration: Double?
    public let echoReturnLoss: Double?
    public let echoReturnLossEnhancement: Double?
    public let droppedSamplesDuration: Double?
    public let droppedSamplesEvents: UInt?
    public let totalCaptureDelay: Double?
    public let totalSamplesCaptured: UInt64?

    override init?(id: String,
                   timestamp: Double,
                   rawValues: [String: NSObject])
    {
        audioLevel = rawValues.readOptional("audioLevel")
        totalAudioEnergy = rawValues.readOptional("totalAudioEnergy")
        totalSamplesDuration = rawValues.readOptional("totalSamplesDuration")
        echoReturnLoss = rawValues.readOptional("echoReturnLoss")
        echoReturnLossEnhancement = rawValues.readOptional("echoReturnLossEnhancement")
        droppedSamplesDuration = rawValues.readOptional("droppedSamplesDuration")
        droppedSamplesEvents = rawValues.readOptional("droppedSamplesEvents")
        totalCaptureDelay = rawValues.readOptional("totalCaptureDelay")
        totalSamplesCaptured = rawValues.readOptional("totalSamplesCaptured")

        super.init(id: id,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

@objc
public class VideoSourceStatistics: MediaSourceStatistics {
    public let width: UInt?
    public let height: UInt?
    public let frames: UInt?
    public let framesPerSecond: Double?

    override init?(id: String,
                   timestamp: Double,
                   rawValues: [String: NSObject])
    {
        width = rawValues.readOptional("width")
        height = rawValues.readOptional("height")
        frames = rawValues.readOptional("frames")
        framesPerSecond = rawValues.readOptional("framesPerSecond")

        super.init(id: id,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

extension [String: NSObject] {
    func readOptional(_ key: String) -> Int? {
        self[key] as? Int
    }

    func readOptional(_ key: String) -> UInt? {
        self[key] as? UInt
    }

    func readOptional(_ key: String) -> UInt64? {
        self[key] as? UInt64
    }

    func readOptional(_ key: String) -> Int64? {
        self[key] as? Int64
    }

    func readOptional(_ key: String) -> UInt16? {
        self[key] as? UInt16
    }

    func readOptional(_ key: String) -> Double? {
        self[key] as? Double
    }

    func readOptional(_ key: String) -> String? {
        self[key] as? String
    }

    func readOptional(_ key: String) -> Bool? {
        self[key] as? Bool
    }

    func readNonOptional(_ key: String) -> String {
        readOptional(key) ?? ""
    }

    func readNonOptional(_ key: String) -> [String: NSObject] {
        (self[key] as? [String: NSObject]) ?? [:]
    }
}
