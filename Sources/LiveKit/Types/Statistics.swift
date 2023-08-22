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

/// Stats spec defined at https://www.w3.org/TR/webrtc-stats/

public enum StatisticsType: String {
    case codec = "codec"
    case inboundRtp = "inbound-rtp"
    case outboundRtp = "outbound-rtp"
    case remoteInboundRtp = "remote-inbound-rtp"
    case remoteOutboundRtp = "remote-outbound-rtp"
    case mediaSource = "media-source"
    case mediaPlayout = "media-playout"
    case peerConnection = "peer-connection"
    case dataChannel = "data-channel"
    case transport = "transport"
    case candidatePair = "candidate-pair"
    case localCandidate = "local-candidate"
    case remoteCandidate = "remote-candidate"
    case certificate = "certificate"
}

public enum QualityLimitationReason: String {
    case none = "none"
    case cpu = "cpu"
    case bandwidth = "bandwidth"
    case other = "other"
}

public enum DtlsRole: String {
    case client = "client"
    case server = "server"
    case unknown = "unknown"
}

public enum IceCandidatePairState: String {
    case frozen = "frozen"
    case waiting = "waiting"
    case inProgress = "in-progress"
    case failed = "failed"
    case succeeded = "succeeded"
}

public enum DataChannelState: String {
    case connecting = "connecting"
    case open = "open"
    case closing = "closing"
    case closed = "closed"
}

public enum IceRole: String {
    case unknown = "unknown"
    case controlling = "controlling"
    case controlled = "controlled"
}

public enum DtlsTransportState: String {
    case new = "new"
    case connecting = "connecting"
    case connected = "connected"
    case closed = "closed"
    case failed = "failed"
}

public enum IceTransportState: String {
    case new = "new"
    case checking = "checking"
    case connected = "connected"
    case completed = "completed"
    case disconnected = "disconnected"
    case failed = "failed"
    case closed = "closed"
}

public enum IceCandidateType: String {
    case host = "host"
    case srflx = "srflx"
    case prflx = "prflx"
    case relay = "relay"
}

public enum IceServerTransportProtocol: String {
    case udp = "udp"
    case tcp = "tcp"
    case tls = "tls"
}

public enum IceTcpCandidateType: String {
    case active = "active"
    case passive = "passive"
    case so = "so"
}

// Base class
@objc
public class Statistics: NSObject, Identifiable {

    public let id: String
    public let type: StatisticsType
    public let timestamp: Double
    public let rawValues: [String: NSObject]

    init?(id: String,
          type: StatisticsType,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.rawValues = rawValues
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
          rawValues: [String: NSObject]) {

        self.payloadType = rawValues.readOptional("payloadType")
        self.transportId = rawValues.readOptional("transportId")
        self.mimeType = rawValues.readOptional("mimeType")
        self.clockRate = rawValues.readOptional("clockRate")
        self.channels = rawValues.readOptional("channels")
        self.sdpFmtpLine = rawValues.readOptional("sdpFmtpLine")

        super.init(id: id,
                   type: .codec,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

@objc
public class MediaSourceStatistics: Statistics {

    public let trackIdentifier: String?
    public let kind: String?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        self.trackIdentifier = rawValues.readOptional("trackIdentifier")
        self.kind = rawValues.readOptional("kind")

        super.init(id: id,
                   type: .mediaSource,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

@objc
public class RtpStreamStatistics: Statistics {

    public let ssrc: UInt?
    public let kind: String?
    public let transportId: String?
    public let codecId: String?

    override init?(id: String,
                   type: StatisticsType,
                   timestamp: Double,
                   rawValues: [String: NSObject]) {

        self.ssrc = rawValues.readOptional("ssrc")
        self.kind = rawValues.readOptional("kind")
        self.transportId = rawValues.readOptional("transportId")
        self.codecId = rawValues.readOptional("codecId")

        super.init(id: id,
                   type: type,
                   timestamp: timestamp,
                   rawValues: rawValues)
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
          rawValues: [String: NSObject]) {

        self.kind = rawValues.readOptional("kind")
        self.synthesizedSamplesDuration = rawValues.readOptional("synthesizedSamplesDuration")
        self.synthesizedSamplesEvents = rawValues.readOptional("synthesizedSamplesEvents")
        self.totalSamplesDuration = rawValues.readOptional("totalSamplesDuration")
        self.totalPlayoutDelay = rawValues.readOptional("totalPlayoutDelay")
        self.totalSamplesCount = rawValues.readOptional("totalSamplesCount")

        super.init(id: id,
                   type: .mediaPlayout,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

// type: peer-connection
@objc
public class PeerConnectionStatistics: Statistics {

    public let dataChannelsOpened: UInt?
    public let dataChannelsClosed: UInt?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        self.dataChannelsOpened = rawValues.readOptional("dataChannelsOpened")
        self.dataChannelsClosed = rawValues.readOptional("dataChannelsClosed")

        super.init(id: id,
                   type: .peerConnection,
                   timestamp: timestamp,
                   rawValues: rawValues)
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
          rawValues: [String: NSObject]) {

        self.label = rawValues.readOptional("label")
        self.protocol = rawValues.readOptional("protocol")
        self.dataChannelIdentifier = rawValues.readOptional("dataChannelIdentifier")
        self.state = DataChannelState(rawValue: rawValues.readNonOptional("state"))
        self.messagesSent = rawValues.readOptional("messagesSent")
        self.bytesSent = rawValues.readOptional("bytesSent")
        self.messagesReceived = rawValues.readOptional("messagesReceived")
        self.bytesReceived = rawValues.readOptional("bytesReceived")

        super.init(id: id,
                   type: .dataChannel,
                   timestamp: timestamp,
                   rawValues: rawValues)
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
          rawValues: [String: NSObject]) {

        self.packetsSent = rawValues.readOptional("packetsSent")
        self.packetsReceived = rawValues.readOptional("packetsReceived")
        self.bytesSent = rawValues.readOptional("bytesSent")
        self.bytesReceived = rawValues.readOptional("bytesReceived")
        self.iceRole = IceRole(rawValue: rawValues.readNonOptional("iceRole"))
        self.iceLocalUsernameFragment = rawValues.readOptional("iceLocalUsernameFragment")
        self.dtlsState = DtlsTransportState(rawValue: rawValues.readNonOptional("dtlsState"))
        self.iceState = IceTransportState(rawValue: rawValues.readNonOptional("iceState"))
        self.selectedCandidatePairId = rawValues.readOptional("selectedCandidatePairId")
        self.localCertificateId = rawValues.readOptional("localCertificateId")
        self.remoteCertificateId = rawValues.readOptional("remoteCertificateId")
        self.tlsVersion = rawValues.readOptional("tlsVersion")
        self.dtlsCipher = rawValues.readOptional("dtlsCipher")
        self.dtlsRole = DtlsRole(rawValue: rawValues.readNonOptional("dtlsRole"))
        self.srtpCipher = rawValues.readOptional("srtpCipher")
        self.selectedCandidatePairChanges = rawValues.readOptional("selectedCandidatePairChanges")

        super.init(id: id,
                   type: .transport,
                   timestamp: timestamp,
                   rawValues: rawValues)
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

    override init?(id: String,
                   type: StatisticsType,
                   timestamp: Double,
                   rawValues: [String: NSObject]) {

        self.transportId = rawValues.readOptional("transportId")
        self.address = rawValues.readOptional("address")
        self.port = rawValues.readOptional("port")
        self.protocol = rawValues.readOptional("protocol")
        self.candidateType =  IceCandidateType(rawValue: rawValues.readNonOptional("candidateType"))
        self.priority = rawValues.readOptional("priority")
        self.url = rawValues.readOptional("url")
        self.relayProtocol = IceServerTransportProtocol(rawValue: rawValues.readNonOptional("relayProtocol"))
        self.foundation = rawValues.readOptional("foundation")
        self.relatedAddress = rawValues.readOptional("relatedAddress")
        self.relatedPort = rawValues.readOptional("relatedPort")
        self.usernameFragment = rawValues.readOptional("usernameFragment")
        self.tcpType = IceTcpCandidateType(rawValue: rawValues.readNonOptional("tcpType"))

        super.init(id: id,
                   type: type,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

@objc
public class LocalIceCandidateStatistics: IceCandidateStatistics {

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

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
          rawValues: [String: NSObject]) {

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
          rawValues: [String: NSObject]) {

        self.transportId = rawValues.readOptional("transportId")
        self.localCandidateId = rawValues.readOptional("localCandidateId")
        self.remoteCandidateId = rawValues.readOptional("remoteCandidateId")
        self.state = IceCandidatePairState(rawValue: rawValues.readNonOptional("state"))
        self.nominated = rawValues.readOptional("nominated")
        self.packetsSent = rawValues.readOptional("packetsSent")
        self.packetsReceived = rawValues.readOptional("packetsReceived")
        self.bytesSent = rawValues.readOptional("bytesSent")
        self.bytesReceived = rawValues.readOptional("bytesReceived")
        self.lastPacketSentTimestamp = rawValues.readOptional("lastPacketSentTimestamp")
        self.lastPacketReceivedTimestamp = rawValues.readOptional("lastPacketReceivedTimestamp")
        self.totalRoundTripTime = rawValues.readOptional("totalRoundTripTime")
        self.currentRoundTripTime = rawValues.readOptional("currentRoundTripTime")
        self.availableOutgoingBitrate = rawValues.readOptional("availableOutgoingBitrate")
        self.availableIncomingBitrate = rawValues.readOptional("availableIncomingBitrate")
        self.requestsReceived = rawValues.readOptional("requestsReceived")
        self.requestsSent = rawValues.readOptional("requestsSent")
        self.responsesReceived = rawValues.readOptional("responsesReceived")
        self.responsesSent = rawValues.readOptional("responsesSent")
        self.consentRequestsSent = rawValues.readOptional("consentRequestsSent")
        self.packetsDiscardedOnSend = rawValues.readOptional("packetsDiscardedOnSend")
        self.bytesDiscardedOnSend = rawValues.readOptional("bytesDiscardedOnSend")

        super.init(id: id,
                   type: .candidatePair,
                   timestamp: timestamp,
                   rawValues: rawValues)
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
          rawValues: [String: NSObject]) {

        self.fingerprint = rawValues.readOptional("fingerprint")
        self.fingerprintAlgorithm = rawValues.readOptional("fingerprintAlgorithm")
        self.base64Certificate = rawValues.readOptional("base64Certificate")
        self.issuerCertificateId = rawValues.readOptional("issuerCertificateId")

        super.init(id: id,
                   type: .certificate,
                   timestamp: timestamp,
                   rawValues: rawValues)
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
                   rawValues: [String: NSObject]) {

        self.packetsReceived = rawValues.readOptional("packetsReceived")
        self.packetsLost = rawValues.readOptional("packetsLost")
        self.jitter = rawValues.readOptional("jitter")

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
                   rawValues: [String: NSObject]) {

        self.packetsSent = rawValues.readOptional("packetsSent")
        self.bytesSent = rawValues.readOptional("bytesSent")

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

    public let previous: InboundRtpStreamStatistics?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject],
          previous: InboundRtpStreamStatistics?) {

        self.trackIdentifier = rawValues.readOptional("trackIdentifier")
        // self.kind = kind
        self.mid = rawValues.readOptional("mid")
        self.remoteId = rawValues.readOptional("remoteId")
        self.framesDecoded = rawValues.readOptional("framesDecoded")
        self.keyFramesDecoded = rawValues.readOptional("keyFramesDecoded")
        self.framesRendered = rawValues.readOptional("framesRendered")
        self.framesDropped = rawValues.readOptional("framesDropped")
        self.frameWidth = rawValues.readOptional("frameWidth")
        self.frameHeight = rawValues.readOptional("frameHeight")
        self.framesPerSecond = rawValues.readOptional("framesPerSecond")
        self.qpSum = rawValues.readOptional("qpSum")
        self.totalDecodeTime = rawValues.readOptional("totalDecodeTime")
        self.totalInterFrameDelay = rawValues.readOptional("totalInterFrameDelay")
        self.totalSquaredInterFrameDelay = rawValues.readOptional("totalSquaredInterFrameDelay")
        self.pauseCount = rawValues.readOptional("pauseCount")
        self.totalPausesDuration = rawValues.readOptional("totalPausesDuration")
        self.freezeCount = rawValues.readOptional("freezeCount")
        self.totalFreezesDuration = rawValues.readOptional("totalFreezesDuration")
        self.lastPacketReceivedTimestamp = rawValues.readOptional("lastPacketReceivedTimestamp")
        self.headerBytesReceived = rawValues.readOptional("headerBytesReceived")
        self.packetsDiscarded = rawValues.readOptional("packetsDiscarded")
        self.fecPacketsReceived = rawValues.readOptional("fecPacketsReceived")
        self.fecPacketsDiscarded = rawValues.readOptional("fecPacketsDiscarded")
        self.bytesReceived = rawValues.readOptional("bytesReceived")
        self.nackCount = rawValues.readOptional("nackCount")
        self.firCount = rawValues.readOptional("firCount")
        self.pliCount = rawValues.readOptional("pliCount")
        self.totalProcessingDelay = rawValues.readOptional("totalProcessingDelay")
        self.estimatedPlayoutTimestamp = rawValues.readOptional("estimatedPlayoutTimestamp")
        self.jitterBufferDelay = rawValues.readOptional("jitterBufferDelay")
        self.jitterBufferTargetDelay = rawValues.readOptional("jitterBufferTargetDelay")
        self.jitterBufferEmittedCount = rawValues.readOptional("jitterBufferEmittedCount")
        self.jitterBufferMinimumDelay = rawValues.readOptional("jitterBufferMinimumDelay")
        self.totalSamplesReceived = rawValues.readOptional("totalSamplesReceived")
        self.concealedSamples = rawValues.readOptional("concealedSamples")
        self.silentConcealedSamples = rawValues.readOptional("silentConcealedSamples")
        self.concealmentEvents = rawValues.readOptional("concealmentEvents")
        self.insertedSamplesForDeceleration = rawValues.readOptional("insertedSamplesForDeceleration")
        self.removedSamplesForAcceleration = rawValues.readOptional("removedSamplesForAcceleration")
        self.audioLevel = rawValues.readOptional("audioLevel")
        self.totalAudioEnergy = rawValues.readOptional("totalAudioEnergy")
        self.totalSamplesDuration = rawValues.readOptional("totalSamplesDuration")
        self.framesReceived = rawValues.readOptional("framesReceived")
        self.decoderImplementation = rawValues.readOptional("decoderImplementation")
        self.playoutId = rawValues.readOptional("playoutId")
        self.powerEfficientDecoder = rawValues.readOptional("powerEfficientDecoder")
        self.framesAssembledFromMultiplePackets = rawValues.readOptional("framesAssembledFromMultiplePackets")
        self.totalAssemblyTime = rawValues.readOptional("totalAssemblyTime")
        self.retransmittedPacketsReceived = rawValues.readOptional("retransmittedPacketsReceived")
        self.retransmittedBytesReceived = rawValues.readOptional("retransmittedBytesReceived")

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
          rawValues: [String: NSObject]) {

        self.localId = rawValues.readOptional("localId")
        self.roundTripTime = rawValues.readOptional("roundTripTime")
        self.totalRoundTripTime = rawValues.readOptional("totalRoundTripTime")
        self.fractionLost = rawValues.readOptional("fractionLost")
        self.roundTripTimeMeasurements = rawValues.readOptional("roundTripTimeMeasurements")

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
            self.none = rawValues.readOptional("none")
            self.cpu = rawValues.readOptional("cpu")
            self.bandwidth = rawValues.readOptional("bandwidth")
            self.other = rawValues.readOptional("other")

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

    public let previous: OutboundRtpStreamStatistics?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject],
          previous: OutboundRtpStreamStatistics?) {

        self.mid = rawValues.readOptional("mid")
        self.mediaSourceId = rawValues.readOptional("mediaSourceId")
        self.remoteId = rawValues.readOptional("remoteId")
        self.rid = rawValues.readOptional("rid")
        self.headerBytesSent = rawValues.readOptional("headerBytesSent")
        self.retransmittedPacketsSent = rawValues.readOptional("retransmittedPacketsSent")
        self.retransmittedBytesSent = rawValues.readOptional("retransmittedBytesSent")
        self.targetBitrate = rawValues.readOptional("targetBitrate")
        self.totalEncodedBytesTarget = rawValues.readOptional("totalEncodedBytesTarget")
        self.frameWidth = rawValues.readOptional("frameWidth")
        self.frameHeight = rawValues.readOptional("frameHeight")
        self.framesPerSecond = rawValues.readOptional("framesPerSecond")
        self.framesSent = rawValues.readOptional("framesSent")
        self.hugeFramesSent = rawValues.readOptional("hugeFramesSent")
        self.framesEncoded = rawValues.readOptional("framesEncoded")
        self.keyFramesEncoded = rawValues.readOptional("keyFramesEncoded")
        self.qpSum = rawValues.readOptional("qpSum")
        self.totalEncodeTime = rawValues.readOptional("totalEncodeTime")
        self.totalPacketSendDelay = rawValues.readOptional("totalPacketSendDelay")
        self.qualityLimitationReason = QualityLimitationReason(rawValue: rawValues.readNonOptional("qualityLimitationReason"))
        self.qualityLimitationDurations = QualityLimitationDurations(rawValues: rawValues.readNonOptional("qualityLimitationDurations"))
        self.qualityLimitationResolutionChanges = rawValues.readOptional("qualityLimitationResolutionChanges")
        self.nackCount = rawValues.readOptional("nackCount")
        self.firCount = rawValues.readOptional("firCount")
        self.pliCount = rawValues.readOptional("pliCount")
        self.encoderImplementation = rawValues.readOptional("encoderImplementation")
        self.powerEfficientEncoder = rawValues.readOptional("powerEfficientEncoder")
        self.active = rawValues.readOptional("active")
        self.scalabilityMode = rawValues.readOptional("scalabilityMode")

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
          rawValues: [String: NSObject]) {

        self.localId = rawValues.readOptional("localId")
        self.remoteTimestamp = rawValues.readOptional("remoteTimestamp")
        self.reportsSent = rawValues.readOptional("reportsSent")
        self.roundTripTime = rawValues.readOptional("roundTripTime")
        self.totalRoundTripTime = rawValues.readOptional("totalRoundTripTime")
        self.roundTripTimeMeasurements = rawValues.readOptional("roundTripTimeMeasurements")

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
                   rawValues: [String: NSObject]) {

        self.audioLevel = rawValues.readOptional("audioLevel")
        self.totalAudioEnergy = rawValues.readOptional("totalAudioEnergy")
        self.totalSamplesDuration = rawValues.readOptional("totalSamplesDuration")
        self.echoReturnLoss = rawValues.readOptional("echoReturnLoss")
        self.echoReturnLossEnhancement = rawValues.readOptional("echoReturnLossEnhancement")
        self.droppedSamplesDuration = rawValues.readOptional("droppedSamplesDuration")
        self.droppedSamplesEvents = rawValues.readOptional("droppedSamplesEvents")
        self.totalCaptureDelay = rawValues.readOptional("totalCaptureDelay")
        self.totalSamplesCaptured = rawValues.readOptional("totalSamplesCaptured")

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
                   rawValues: [String: NSObject]) {

        self.width = rawValues.readOptional("width")
        self.height = rawValues.readOptional("height")
        self.frames = rawValues.readOptional("frames")
        self.framesPerSecond = rawValues.readOptional("framesPerSecond")

        super.init(id: id,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

internal extension Dictionary where Key == String, Value == NSObject {

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
