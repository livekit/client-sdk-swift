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

    public let payloadType: UInt
    public let transportId: String
    public let mimeType: String
    public let clockRate: UInt
    public let channels: UInt
    public let sdpFmtpLine: String

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        self.payloadType = rawValues.read("payloadType")
        self.transportId = rawValues.read("transportId")
        self.mimeType = rawValues.read("mimeType")
        self.clockRate = rawValues.read("clockRate")
        self.channels = rawValues.read("channels")
        self.sdpFmtpLine = rawValues.read("sdpFmtpLine")

        super.init(id: id,
                   type: .codec,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

@objc
public class MediaSourceStatistics: Statistics {

    public let trackIdentifier: String
    public let kind: String

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        self.trackIdentifier = rawValues.read("trackIdentifier")
        self.kind = rawValues.read("kind")

        super.init(id: id,
                   type: .mediaSource,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

@objc
public class RtpStreamStatistics: Statistics {

    public let ssrc: UInt
    public let kind: String
    public let transportId: String
    public let codecId: String

    override init?(id: String,
                   type: StatisticsType,
                   timestamp: Double,
                   rawValues: [String: NSObject]) {

        self.ssrc = rawValues.read("ssrc")
        self.kind = rawValues.read("kind")
        self.transportId = rawValues.read("transportId")
        self.codecId = rawValues.read("codecId")

        super.init(id: id,
                   type: type,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

// type: media-playout
@objc
public class AudioPlayoutStatistics: Statistics {

    public let kind: String
    public let synthesizedSamplesDuration: Double
    public let synthesizedSamplesEvents: UInt
    public let totalSamplesDuration: Double
    public let totalPlayoutDelay: Double
    public let totalSamplesCount: UInt64

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        self.kind = rawValues.read("kind")
        self.synthesizedSamplesDuration = rawValues.read("synthesizedSamplesDuration")
        self.synthesizedSamplesEvents = rawValues.read("synthesizedSamplesEvents")
        self.totalSamplesDuration = rawValues.read("totalSamplesDuration")
        self.totalPlayoutDelay = rawValues.read("totalPlayoutDelay")
        self.totalSamplesCount = rawValues.read("totalSamplesCount")

        super.init(id: id,
                   type: .mediaPlayout,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

// type: peer-connection
@objc
public class PeerConnectionStatistics: Statistics {

    public let dataChannelsOpened: UInt
    public let dataChannelsClosed: UInt

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        self.dataChannelsOpened = rawValues.read("dataChannelsOpened")
        self.dataChannelsClosed = rawValues.read("dataChannelsClosed")

        super.init(id: id,
                   type: .peerConnection,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

// type: data-channel
@objc
public class DataChannelStatistics: Statistics {

    public let label: String
    public let `protocol`: String
    public let dataChannelIdentifier: UInt16
    public let state: DataChannelState?
    public let messagesSent: UInt
    public let bytesSent: UInt64
    public let messagesReceived: UInt
    public let bytesReceived: UInt64

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        self.label = rawValues.read("label")
        self.protocol = rawValues.read("protocol")
        self.dataChannelIdentifier = rawValues.read("dataChannelIdentifier")
        self.state = DataChannelState(rawValue: rawValues.read("state"))
        self.messagesSent = rawValues.read("messagesSent")
        self.bytesSent = rawValues.read("bytesSent")
        self.messagesReceived = rawValues.read("messagesReceived")
        self.bytesReceived = rawValues.read("bytesReceived")

        super.init(id: id,
                   type: .dataChannel,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

// type: transport
@objc
public class TransportStatistics: Statistics {

    public let packetsSent: UInt64
    public let packetsReceived: UInt64
    public let bytesSent: UInt64
    public let bytesReceived: UInt64
    public let iceRole: IceRole?
    public let iceLocalUsernameFragment: String
    public let dtlsState: DtlsTransportState?
    public let iceState: IceTransportState?
    public let selectedCandidatePairId: String
    public let localCertificateId: String
    public let remoteCertificateId: String
    public let tlsVersion: String
    public let dtlsCipher: String
    public let dtlsRole: DtlsRole?
    public let srtpCipher: String
    public let selectedCandidatePairChanges: UInt

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        self.packetsSent = rawValues.read("packetsSent")
        self.packetsReceived = rawValues.read("packetsReceived")
        self.bytesSent = rawValues.read("bytesSent")
        self.bytesReceived = rawValues.read("bytesReceived")
        self.iceRole = IceRole(rawValue: rawValues.read("iceRole"))
        self.iceLocalUsernameFragment = rawValues.read("iceLocalUsernameFragment")
        self.dtlsState = DtlsTransportState(rawValue: rawValues.read("dtlsState"))
        self.iceState = IceTransportState(rawValue: rawValues.read("iceState"))
        self.selectedCandidatePairId = rawValues.read("selectedCandidatePairId")
        self.localCertificateId = rawValues.read("localCertificateId")
        self.remoteCertificateId = rawValues.read("remoteCertificateId")
        self.tlsVersion = rawValues.read("tlsVersion")
        self.dtlsCipher = rawValues.read("dtlsCipher")
        self.dtlsRole = DtlsRole(rawValue: rawValues.read("dtlsRole"))
        self.srtpCipher = rawValues.read("srtpCipher")
        self.selectedCandidatePairChanges = rawValues.read("selectedCandidatePairChanges")

        super.init(id: id,
                   type: .transport,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

// type: local-candidate, remote-candidate
@objc
public class IceCandidateStatistics: Statistics {

    public let transportId: String
    public let address: String
    public let port: Int
    public let `protocol`: String
    public let candidateType: IceCandidateType?
    public let priority: Int
    public let url: String
    public let relayProtocol: IceServerTransportProtocol?
    public let foundation: String
    public let relatedAddress: String
    public let relatedPort: Int
    public let usernameFragment: String
    public let tcpType: IceTcpCandidateType?

    override init?(id: String,
                   type: StatisticsType,
                   timestamp: Double,
                   rawValues: [String: NSObject]) {

        self.transportId = rawValues.read("transportId")
        self.address = rawValues.read("address")
        self.port = rawValues.read("port")
        self.protocol = rawValues.read("protocol")
        self.candidateType = IceCandidateType(rawValue: rawValues.read("candidateType"))
        self.priority = rawValues.read("priority")
        self.url = rawValues.read("url")
        self.relayProtocol = IceServerTransportProtocol(rawValue: rawValues.read("relayProtocol"))
        self.foundation = rawValues.read("foundation")
        self.relatedAddress = rawValues.read("relatedAddress")
        self.relatedPort = rawValues.read("relatedPort")
        self.usernameFragment = rawValues.read("usernameFragment")
        self.tcpType = IceTcpCandidateType(rawValue: rawValues.read("tcpType"))

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

    public let transportId: String
    public let localCandidateId: String
    public let remoteCandidateId: String
    public let state: IceCandidatePairState?
    public let nominated: Bool
    public let packetsSent: UInt64
    public let packetsReceived: UInt64
    public let bytesSent: UInt64
    public let bytesReceived: UInt64
    public let lastPacketSentTimestamp: Double
    public let lastPacketReceivedTimestamp: Double
    public let totalRoundTripTime: Double
    public let currentRoundTripTime: Double
    public let availableOutgoingBitrate: Double
    public let availableIncomingBitrate: Double
    public let requestsReceived: UInt64
    public let requestsSent: UInt64
    public let responsesReceived: UInt64
    public let responsesSent: UInt64
    public let consentRequestsSent: UInt64
    public let packetsDiscardedOnSend: UInt
    public let bytesDiscardedOnSend: UInt64

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        self.transportId = rawValues.read("transportId")
        self.localCandidateId = rawValues.read("localCandidateId")
        self.remoteCandidateId = rawValues.read("remoteCandidateId")
        self.state = IceCandidatePairState(rawValue: rawValues.read("state"))
        self.nominated = rawValues.read("nominated")
        self.packetsSent = rawValues.read("packetsSent")
        self.packetsReceived = rawValues.read("packetsReceived")
        self.bytesSent = rawValues.read("bytesSent")
        self.bytesReceived = rawValues.read("bytesReceived")
        self.lastPacketSentTimestamp = rawValues.read("lastPacketSentTimestamp")
        self.lastPacketReceivedTimestamp = rawValues.read("lastPacketReceivedTimestamp")
        self.totalRoundTripTime = rawValues.read("totalRoundTripTime")
        self.currentRoundTripTime = rawValues.read("currentRoundTripTime")
        self.availableOutgoingBitrate = rawValues.read("availableOutgoingBitrate")
        self.availableIncomingBitrate = rawValues.read("availableIncomingBitrate")
        self.requestsReceived = rawValues.read("requestsReceived")
        self.requestsSent = rawValues.read("requestsSent")
        self.responsesReceived = rawValues.read("responsesReceived")
        self.responsesSent = rawValues.read("responsesSent")
        self.consentRequestsSent = rawValues.read("consentRequestsSent")
        self.packetsDiscardedOnSend = rawValues.read("packetsDiscardedOnSend")
        self.bytesDiscardedOnSend = rawValues.read("bytesDiscardedOnSend")

        super.init(id: id,
                   type: .candidatePair,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

// type: certificate
@objc
public class CertificateStatistics: Statistics {

    public let fingerprint: String
    public let fingerprintAlgorithm: String
    public let base64Certificate: String
    public let issuerCertificateId: String

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        self.fingerprint = rawValues.read("fingerprint")
        self.fingerprintAlgorithm = rawValues.read("fingerprintAlgorithm")
        self.base64Certificate = rawValues.read("base64Certificate")
        self.issuerCertificateId = rawValues.read("issuerCertificateId")

        super.init(id: id,
                   type: .certificate,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

@objc
public class ReceivedRtpStreamStatistics: RtpStreamStatistics {

    public let packetsReceived: UInt64
    public let packetsLost: Int64
    public let jitter: Double

    override init?(id: String,
                   type: StatisticsType,
                   timestamp: Double,
                   rawValues: [String: NSObject]) {

        self.packetsReceived = rawValues.read("packetsReceived")
        self.packetsLost = rawValues.read("packetsLost")
        self.jitter = rawValues.read("jitter")

        super.init(id: id,
                   type: type,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

@objc
public class SentRtpStreamStatistics: RtpStreamStatistics {

    public let packetsSent: UInt64
    public let bytesSent: UInt64

    override init?(id: String,
                   type: StatisticsType,
                   timestamp: Double,
                   rawValues: [String: NSObject]) {

        self.packetsSent = rawValues.read("packetsSent")
        self.bytesSent = rawValues.read("bytesSent")

        super.init(id: id,
                   type: type,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

// type: inbound-rtp
@objc
public class InboundRtpStreamStatistics: ReceivedRtpStreamStatistics {

    public let trackIdentifier: String
    // let kind: String
    public let mid: String
    public let remoteId: String
    public let framesDecoded: UInt
    public let keyFramesDecoded: UInt
    public let framesRendered: UInt
    public let framesDropped: UInt
    public let frameWidth: UInt
    public let frameHeight: UInt
    public let framesPerSecond: Double
    public let qpSum: UInt64
    public let totalDecodeTime: Double
    public let totalInterFrameDelay: Double
    public let totalSquaredInterFrameDelay: Double
    public let pauseCount: UInt
    public let totalPausesDuration: Double
    public let freezeCount: UInt
    public let totalFreezesDuration: Double
    public let lastPacketReceivedTimestamp: Double
    public let headerBytesReceived: UInt64
    public let packetsDiscarded: UInt64
    public let fecPacketsReceived: UInt64
    public let fecPacketsDiscarded: UInt64
    public let bytesReceived: UInt64
    public let nackCount: UInt
    public let firCount: UInt
    public let pliCount: UInt
    public let totalProcessingDelay: Double
    public let estimatedPlayoutTimestamp: Double
    public let jitterBufferDelay: Double
    public let jitterBufferTargetDelay: Double
    public let jitterBufferEmittedCount: UInt64
    public let jitterBufferMinimumDelay: Double
    public let totalSamplesReceived: UInt64
    public let concealedSamples: UInt64
    public let silentConcealedSamples: UInt64
    public let concealmentEvents: UInt64
    public let insertedSamplesForDeceleration: UInt64
    public let removedSamplesForAcceleration: UInt64
    public let audioLevel: Double
    public let totalAudioEnergy: Double
    public let totalSamplesDuration: Double
    public let framesReceived: UInt
    public let decoderImplementation: String
    public let playoutId: String
    public let powerEfficientDecoder: Bool
    public let framesAssembledFromMultiplePackets: UInt
    public let totalAssemblyTime: Double
    public let retransmittedPacketsReceived: UInt64
    public let retransmittedBytesReceived: UInt64

    public let previous: InboundRtpStreamStatistics?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject],
          previous: InboundRtpStreamStatistics?) {

        self.trackIdentifier = rawValues.read("trackIdentifier")
        // self.kind = kind
        self.mid = rawValues.read("mid")
        self.remoteId = rawValues.read("remoteId")
        self.framesDecoded = rawValues.read("framesDecoded")
        self.keyFramesDecoded = rawValues.read("keyFramesDecoded")
        self.framesRendered = rawValues.read("framesRendered")
        self.framesDropped = rawValues.read("framesDropped")
        self.frameWidth = rawValues.read("frameWidth")
        self.frameHeight = rawValues.read("frameHeight")
        self.framesPerSecond = rawValues.read("framesPerSecond")
        self.qpSum = rawValues.read("qpSum")
        self.totalDecodeTime = rawValues.read("totalDecodeTime")
        self.totalInterFrameDelay = rawValues.read("totalInterFrameDelay")
        self.totalSquaredInterFrameDelay = rawValues.read("totalSquaredInterFrameDelay")
        self.pauseCount = rawValues.read("pauseCount")
        self.totalPausesDuration = rawValues.read("totalPausesDuration")
        self.freezeCount = rawValues.read("freezeCount")
        self.totalFreezesDuration = rawValues.read("totalFreezesDuration")
        self.lastPacketReceivedTimestamp = rawValues.read("lastPacketReceivedTimestamp")
        self.headerBytesReceived = rawValues.read("headerBytesReceived")
        self.packetsDiscarded = rawValues.read("packetsDiscarded")
        self.fecPacketsReceived = rawValues.read("fecPacketsReceived")
        self.fecPacketsDiscarded = rawValues.read("fecPacketsDiscarded")
        self.bytesReceived = rawValues.read("bytesReceived")
        self.nackCount = rawValues.read("nackCount")
        self.firCount = rawValues.read("firCount")
        self.pliCount = rawValues.read("pliCount")
        self.totalProcessingDelay = rawValues.read("totalProcessingDelay")
        self.estimatedPlayoutTimestamp = rawValues.read("estimatedPlayoutTimestamp")
        self.jitterBufferDelay = rawValues.read("jitterBufferDelay")
        self.jitterBufferTargetDelay = rawValues.read("jitterBufferTargetDelay")
        self.jitterBufferEmittedCount = rawValues.read("jitterBufferEmittedCount")
        self.jitterBufferMinimumDelay = rawValues.read("jitterBufferMinimumDelay")
        self.totalSamplesReceived = rawValues.read("totalSamplesReceived")
        self.concealedSamples = rawValues.read("concealedSamples")
        self.silentConcealedSamples = rawValues.read("silentConcealedSamples")
        self.concealmentEvents = rawValues.read("concealmentEvents")
        self.insertedSamplesForDeceleration = rawValues.read("insertedSamplesForDeceleration")
        self.removedSamplesForAcceleration = rawValues.read("removedSamplesForAcceleration")
        self.audioLevel = rawValues.read("audioLevel")
        self.totalAudioEnergy = rawValues.read("totalAudioEnergy")
        self.totalSamplesDuration = rawValues.read("totalSamplesDuration")
        self.framesReceived = rawValues.read("framesReceived")
        self.decoderImplementation = rawValues.read("decoderImplementation")
        self.playoutId = rawValues.read("playoutId")
        self.powerEfficientDecoder = rawValues.read("powerEfficientDecoder")
        self.framesAssembledFromMultiplePackets = rawValues.read("framesAssembledFromMultiplePackets")
        self.totalAssemblyTime = rawValues.read("totalAssemblyTime")
        self.retransmittedPacketsReceived = rawValues.read("retransmittedPacketsReceived")
        self.retransmittedBytesReceived = rawValues.read("retransmittedBytesReceived")

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

    public let localId: String
    public let roundTripTime: Double
    public let totalRoundTripTime: Double
    public let fractionLost: Double
    public let roundTripTimeMeasurements: UInt64

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        self.localId = rawValues.read("localId")
        self.roundTripTime = rawValues.read("roundTripTime")
        self.totalRoundTripTime = rawValues.read("totalRoundTripTime")
        self.fractionLost = rawValues.read("fractionLost")
        self.roundTripTimeMeasurements = rawValues.read("roundTripTimeMeasurements")

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

        public let none: Double
        public let cpu: Double
        public let bandwidth: Double
        public let other: Double

        init(rawValues: [String: NSObject]) {
            self.none = rawValues.read("none")
            self.cpu = rawValues.read("cpu")
            self.bandwidth = rawValues.read("bandwidth")
            self.other = rawValues.read("other")
        }
    }

    public let mid: String
    public let mediaSourceId: String
    public let remoteId: String
    public let rid: String
    public let headerBytesSent: UInt64
    public let retransmittedPacketsSent: UInt64
    public let retransmittedBytesSent: UInt64
    public let targetBitrate: Double
    public let totalEncodedBytesTarget: UInt64
    public let frameWidth: UInt
    public let frameHeight: UInt
    public let framesPerSecond: Double
    public let framesSent: UInt
    public let hugeFramesSent: UInt
    public let framesEncoded: UInt
    public let keyFramesEncoded: UInt
    public let qpSum: UInt64
    public let totalEncodeTime: Double
    public let totalPacketSendDelay: Double
    public let qualityLimitationReason: QualityLimitationReason
    public let qualityLimitationDurations: QualityLimitationDurations
    public let qualityLimitationResolutionChanges: UInt
    public let nackCount: UInt
    public let firCount: UInt
    public let pliCount: UInt
    public let encoderImplementation: String
    public let powerEfficientEncoder: Bool
    public let active: Bool
    public let scalabilityMode: String

    public let previous: OutboundRtpStreamStatistics?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject],
          previous: OutboundRtpStreamStatistics?) {

        self.mid = rawValues.read("mid")
        self.mediaSourceId = rawValues.read("mediaSourceId")
        self.remoteId = rawValues.read("remoteId")
        self.rid = rawValues.read("rid")
        self.headerBytesSent = rawValues.read("headerBytesSent")
        self.retransmittedPacketsSent = rawValues.read("retransmittedPacketsSent")
        self.retransmittedBytesSent = rawValues.read("retransmittedBytesSent")
        self.targetBitrate = rawValues.read("targetBitrate")
        self.totalEncodedBytesTarget = rawValues.read("totalEncodedBytesTarget")
        self.frameWidth = rawValues.read("frameWidth")
        self.frameHeight = rawValues.read("frameHeight")
        self.framesPerSecond = rawValues.read("framesPerSecond")
        self.framesSent = rawValues.read("framesSent")
        self.hugeFramesSent = rawValues.read("hugeFramesSent")
        self.framesEncoded = rawValues.read("framesEncoded")
        self.keyFramesEncoded = rawValues.read("keyFramesEncoded")
        self.qpSum = rawValues.read("qpSum")
        self.totalEncodeTime = rawValues.read("totalEncodeTime")
        self.totalPacketSendDelay = rawValues.read("totalPacketSendDelay")
        self.qualityLimitationReason = QualityLimitationReason(rawValue: (rawValues.read("qualityLimitationReason"))) ?? .none
        self.qualityLimitationDurations = QualityLimitationDurations(rawValues: rawValues.read("qualityLimitationDurations"))
        self.qualityLimitationResolutionChanges = rawValues.read("qualityLimitationResolutionChanges")
        self.nackCount = rawValues.read("nackCount")
        self.firCount = rawValues.read("firCount")
        self.pliCount = rawValues.read("pliCount")
        self.encoderImplementation = rawValues.read("encoderImplementation")
        self.powerEfficientEncoder = rawValues.read("powerEfficientEncoder")
        self.active = rawValues.read("active")
        self.scalabilityMode = rawValues.read("scalabilityMode")

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

    public let localId: String
    public let remoteTimestamp: Double
    public let reportsSent: UInt64
    public let roundTripTime: Double
    public let totalRoundTripTime: Double
    public let roundTripTimeMeasurements: UInt64

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        self.localId = rawValues.read("localId")
        self.remoteTimestamp = rawValues.read("remoteTimestamp")
        self.reportsSent = rawValues.read("reportsSent")
        self.roundTripTime = rawValues.read("roundTripTime")
        self.totalRoundTripTime = rawValues.read("totalRoundTripTime")
        self.roundTripTimeMeasurements = rawValues.read("roundTripTimeMeasurements")

        super.init(id: id,
                   type: .remoteOutboundRtp,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

@objc
public class AudioSourceStatistics: MediaSourceStatistics {

    public let audioLevel: Double
    public let totalAudioEnergy: Double
    public let totalSamplesDuration: Double
    public let echoReturnLoss: Double
    public let echoReturnLossEnhancement: Double
    public let droppedSamplesDuration: Double
    public let droppedSamplesEvents: UInt
    public let totalCaptureDelay: Double
    public let totalSamplesCaptured: UInt64

    override init?(id: String,
                   timestamp: Double,
                   rawValues: [String: NSObject]) {

        self.audioLevel = rawValues.read("audioLevel")
        self.totalAudioEnergy = rawValues.read("totalAudioEnergy")
        self.totalSamplesDuration = rawValues.read("totalSamplesDuration")
        self.echoReturnLoss = rawValues.read("echoReturnLoss")
        self.echoReturnLossEnhancement = rawValues.read("echoReturnLossEnhancement")
        self.droppedSamplesDuration = rawValues.read("droppedSamplesDuration")
        self.droppedSamplesEvents = rawValues.read("droppedSamplesEvents")
        self.totalCaptureDelay = rawValues.read("totalCaptureDelay")
        self.totalSamplesCaptured = rawValues.read("totalSamplesCaptured")

        super.init(id: id,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

@objc
public class VideoSourceStatistics: MediaSourceStatistics {

    public let width: UInt
    public let height: UInt
    public let frames: UInt
    public let framesPerSecond: Double

    override init?(id: String,
                   timestamp: Double,
                   rawValues: [String: NSObject]) {

        self.width = rawValues.read("width")
        self.height = rawValues.read("height")
        self.frames = rawValues.read("frames")
        self.framesPerSecond = rawValues.read("framesPerSecond")

        super.init(id: id,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

internal extension Dictionary where Key == String, Value == NSObject {

    func read(_ key: String) -> Int {
        (self[key] as? Int) ?? 0
    }

    func read(_ key: String) -> UInt {
        (self[key] as? UInt) ?? 0
    }

    func read(_ key: String) -> UInt64 {
        (self[key] as? UInt64) ?? 0
    }

    func read(_ key: String) -> Int64 {
        (self[key] as? Int64) ?? 0
    }

    func read(_ key: String) -> UInt16 {
        (self[key] as? UInt16) ?? 0
    }

    func read(_ key: String) -> Double {
        (self[key] as? Double) ?? 0.0
    }

    func read(_ key: String) -> String {
        (self[key] as? String) ?? ""
    }

    func read(_ key: String) -> Bool {
        (self[key] as? Bool) ?? false
    }

    func read(_ key: String) -> [String: NSObject] {
        (self[key] as? [String: NSObject]) ?? [:]
    }
}
