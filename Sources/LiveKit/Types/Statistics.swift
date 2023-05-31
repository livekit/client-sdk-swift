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

/// RTCStatsType represents statistics related to different aspects of the RTCPeerConnection.
public enum StatisticsType: String {
    /// Represents statistics for a codec that is currently being used by RTP streams being sent or received by this RTCPeerConnection object.
    case codec = "codec"

    /// Represents statistics for an inbound RTP stream that is currently received with this RTCPeerConnection object.
    case inboundRtp = "inbound-rtp"

    /// Represents statistics for an outbound RTP stream that is currently sent with this RTCPeerConnection object.
    case outboundRtp = "outbound-rtp"

    /// Represents statistics for the remote endpoint's inbound RTP stream corresponding to an outbound stream that is currently sent with this RTCPeerConnection object.
    case remoteInboundRtp = "remote-inbound-rtp"

    /// Represents statistics for the remote endpoint's outbound RTP stream corresponding to an inbound stream that is currently received with this RTCPeerConnection object.
    case remoteOutboundRtp = "remote-outbound-rtp"

    /// Represents statistics for the media produced by a MediaStreamTrack that is currently attached to an RTCRtpSender.
    case mediaSource = "media-source"

    /// Represents statistics related to audio playout.
    case mediaPlayout = "media-playout"

    /// Represents statistics related to the RTCPeerConnection object.
    case peerConnection = "peer-connection"

    /// Represents statistics related to each RTCDataChannel id.
    case dataChannel = "data-channel"

    /// Represents transport statistics related to the RTCPeerConnection object.
    case transport = "transport"

    /// Represents ICE candidate pair statistics related to the RTCIceTransport objects.
    case candidatePair = "candidate-pair"

    /// Represents ICE local candidate statistics related to the RTCIceTransport objects.
    case localCandidate = "local-candidate"

    /// Represents ICE remote candidate statistics related to the RTCIceTransport objects.
    case remoteCandidate = "remote-candidate"

    /// Represents information about a certificate used by an RTCIceTransport.
    case certificate = "certificate"
}

/// RTCQualityLimitationReason represents the reason why the quality of a video might be limited.
public enum QualityLimitationReason: String {
    /// The resolution and/or framerate is not limited.
    case none = "none"

    /// The resolution and/or framerate is primarily limited due to CPU load.
    case cpu = "cpu"

    /// The resolution and/or framerate is primarily limited due to congestion cues during bandwidth estimation.
    case bandwidth = "bandwidth"

    /// The resolution and/or framerate is primarily limited for a reason other than the above.
    case other = "other"
}

/// RTCDtlsRole represents the role that the RTCPeerConnection is playing in the DTLS handshake.
public enum DtlsRole: String {
    /// The RTCPeerConnection is acting as a DTLS client as defined in [RFC6347].
    case client = "client"

    /// The RTCPeerConnection is acting as a DTLS server as defined in [RFC6347].
    case server = "server"

    /// The DTLS role of the RTCPeerConnection has not been determined yet.
    case unknown = "unknown"
}

/// RTCStatsIceCandidatePairState represents the state of the ICE candidate pair as defined in Section 5.7.4 of [RFC5245].
public enum IceCandidatePairState: String {
    /// The state is defined in Section 5.7.4 of [RFC5245].
    case frozen = "frozen"

    /// The state is defined in Section 5.7.4 of [RFC5245].
    case waiting = "waiting"

    /// The state is defined in Section 5.7.4 of [RFC5245].
    case inProgress = "in-progress"

    /// The state is defined in Section 5.7.4 of [RFC5245].
    case failed = "failed"

    /// The state is defined in Section 5.7.4 of [RFC5245].
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
    public let clockRate: UInt?
    public let channels: UInt?
    public let sdpFmtpLine: String?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        guard let payloadType = rawValues["payloadType"] as? UInt,
              let transportId = rawValues["transportId"] as? String,
              let mimeType = rawValues["mimeType"] as? String else { return nil }

        self.payloadType = payloadType
        self.transportId = transportId
        self.mimeType = mimeType
        self.clockRate = rawValues["clockRate"] as? UInt
        self.channels = rawValues["channels"] as? UInt
        self.sdpFmtpLine = rawValues["sdpFmtpLine"] as? String

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

        guard let trackIdentifier = rawValues["trackIdentifier"] as? String,
              let kind = rawValues["kind"] as? String else { return nil }

        self.trackIdentifier = trackIdentifier
        self.kind = kind

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
    public let transportId: String?
    public let codecId: String?

    override init?(id: String,
                   type: StatisticsType,
                   timestamp: Double,
                   rawValues: [String: NSObject]) {

        guard let ssrc = rawValues["ssrc"] as? UInt,
              let kind = rawValues["kind"] as? String else { return nil }

        self.ssrc = ssrc
        self.kind = kind
        self.transportId = rawValues["transportId"] as? String
        self.codecId = rawValues["codecId"] as? String

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
    public let synthesizedSamplesDuration: Double?
    public let synthesizedSamplesEvents: UInt?
    public let totalSamplesDuration: Double?
    public let totalPlayoutDelay: Double?
    public let totalSamplesCount: UInt64?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        guard let kind = rawValues["kind"] as? String else { return nil }

        self.kind = kind
        self.synthesizedSamplesDuration = rawValues["synthesizedSamplesDuration"] as? Double
        self.synthesizedSamplesEvents = rawValues["synthesizedSamplesEvents"] as? UInt
        self.totalSamplesDuration = rawValues["totalSamplesDuration"] as? Double
        self.totalPlayoutDelay = rawValues["totalPlayoutDelay"] as? Double
        self.totalSamplesCount = rawValues["totalSamplesCount"] as? UInt64

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

        self.dataChannelsOpened = rawValues["dataChannelsOpened"] as? UInt
        self.dataChannelsClosed = rawValues["dataChannelsClosed"] as? UInt

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

        self.label = rawValues["label"] as? String
        self.protocol = rawValues["protocol"] as? String
        self.dataChannelIdentifier = rawValues["dataChannelIdentifier"] as? UInt16
        self.state = DataChannelState(rawValue: rawValues["state"] as? String ?? "")
        self.messagesSent = rawValues["messagesSent"] as? UInt
        self.bytesSent = rawValues["bytesSent"] as? UInt64
        self.messagesReceived = rawValues["messagesReceived"] as? UInt
        self.bytesReceived = rawValues["bytesReceived"] as? UInt64

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

        self.packetsSent = rawValues["packetsSent"] as? UInt64
        self.packetsReceived = rawValues["packetsReceived"] as? UInt64
        self.bytesSent = rawValues["bytesSent"] as? UInt64
        self.bytesReceived = rawValues["bytesReceived"] as? UInt64
        self.iceRole = IceRole(rawValue: rawValues["iceRole"] as? String ?? "")
        self.iceLocalUsernameFragment = rawValues["iceLocalUsernameFragment"] as? String
        self.dtlsState = DtlsTransportState(rawValue: rawValues["dtlsState"] as? String ?? "")
        self.iceState = IceTransportState(rawValue: rawValues["iceState"] as? String ?? "")
        self.selectedCandidatePairId = rawValues["selectedCandidatePairId"] as? String
        self.localCertificateId = rawValues["localCertificateId"] as? String
        self.remoteCertificateId = rawValues["remoteCertificateId"] as? String
        self.tlsVersion = rawValues["tlsVersion"] as? String
        self.dtlsCipher = rawValues["dtlsCipher"] as? String
        self.dtlsRole = DtlsRole(rawValue: rawValues["dtlsRole"] as? String ?? "")
        self.srtpCipher = rawValues["srtpCipher"] as? String
        self.selectedCandidatePairChanges = rawValues["selectedCandidatePairChanges"] as? UInt

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

        guard let transportId = rawValues["transportId"] as? String else { return nil }

        self.transportId = transportId
        self.address = rawValues["address"] as? String
        self.port = rawValues["port"] as? Int
        self.protocol = rawValues["protocol"] as? String
        self.candidateType = IceCandidateType(rawValue: rawValues["candidateType"] as? String ?? "")
        self.priority = rawValues["priority"] as? Int
        self.url = rawValues["url"] as? String
        self.relayProtocol = IceServerTransportProtocol(rawValue: rawValues["relayProtocol"] as? String ?? "")
        self.foundation = rawValues["foundation"] as? String
        self.relatedAddress = rawValues["relatedAddress"] as? String
        self.relatedPort = rawValues["relatedPort"] as? Int
        self.usernameFragment = rawValues["usernameFragment"] as? String
        self.tcpType = IceTcpCandidateType(rawValue: rawValues["tcpType"] as? String ?? "")

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
    public let state: IceCandidatePairState
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

        guard let transportId = rawValues["transportId"] as? String,
              let localCandidateId = rawValues["localCandidateId"] as? String,
              let remoteCandidateId = rawValues["remoteCandidateId"] as? String,
              let state = IceCandidatePairState(rawValue: rawValues["state"] as? String ?? "") else { return nil }

        self.transportId = transportId
        self.localCandidateId = localCandidateId
        self.remoteCandidateId = remoteCandidateId
        self.state = state
        self.nominated = rawValues["nominated"] as? Bool
        self.packetsSent = rawValues["packetsSent"] as? UInt64
        self.packetsReceived = rawValues["packetsReceived"] as? UInt64
        self.bytesSent = rawValues["bytesSent"] as? UInt64
        self.bytesReceived = rawValues["bytesReceived"] as? UInt64
        self.lastPacketSentTimestamp = rawValues["lastPacketSentTimestamp"] as? Double
        self.lastPacketReceivedTimestamp = rawValues["lastPacketReceivedTimestamp"] as? Double
        self.totalRoundTripTime = rawValues["totalRoundTripTime"] as? Double
        self.currentRoundTripTime = rawValues["currentRoundTripTime"] as? Double
        self.availableOutgoingBitrate = rawValues["availableOutgoingBitrate"] as? Double
        self.availableIncomingBitrate = rawValues["availableIncomingBitrate"] as? Double
        self.requestsReceived = rawValues["requestsReceived"] as? UInt64
        self.requestsSent = rawValues["requestsSent"] as? UInt64
        self.responsesReceived = rawValues["responsesReceived"] as? UInt64
        self.responsesSent = rawValues["responsesSent"] as? UInt64
        self.consentRequestsSent = rawValues["consentRequestsSent"] as? UInt64
        self.packetsDiscardedOnSend = rawValues["packetsDiscardedOnSend"] as? UInt
        self.bytesDiscardedOnSend = rawValues["bytesDiscardedOnSend"] as? UInt64

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
    public let issuerCertificateId: String?

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        guard let fingerprint = rawValues["fingerprint"] as? String,
              let fingerprintAlgorithm = rawValues["fingerprintAlgorithm"] as? String,
              let base64Certificate = rawValues["base64Certificate"] as? String else { return nil }

        self.fingerprint = fingerprint
        self.fingerprintAlgorithm = fingerprintAlgorithm
        self.base64Certificate = base64Certificate
        self.issuerCertificateId = rawValues["issuerCertificateId"] as? String

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

        self.packetsReceived = rawValues["packetsReceived"] as? UInt64
        self.packetsLost = rawValues["packetsLost"] as? Int64
        self.jitter = rawValues["jitter"] as? Double

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

        self.packetsSent = (rawValues["packetsSent"] as? UInt64) ?? 0
        self.bytesSent = (rawValues["bytesSent"] as? UInt64) ?? 0

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
    public let headerBytesReceived: UInt64
    public let packetsDiscarded: UInt64?
    public let fecPacketsReceived: UInt64
    public let fecPacketsDiscarded: UInt64
    public let bytesReceived: UInt64
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

        self.trackIdentifier = rawValues["trackIdentifier"] as? String
        // self.kind = kind
        self.mid = rawValues["mid"] as? String
        self.remoteId = rawValues["remoteId"] as? String
        self.framesDecoded = rawValues["framesDecoded"] as? UInt
        self.keyFramesDecoded = rawValues["keyFramesDecoded"] as? UInt
        self.framesRendered = rawValues["framesRendered"] as? UInt
        self.framesDropped = rawValues["framesDropped"] as? UInt
        self.frameWidth = rawValues["frameWidth"] as? UInt
        self.frameHeight = rawValues["frameHeight"] as? UInt
        self.framesPerSecond = rawValues["framesPerSecond"] as? Double
        self.qpSum = rawValues["qpSum"] as? UInt64
        self.totalDecodeTime = rawValues["totalDecodeTime"] as? Double
        self.totalInterFrameDelay = rawValues["totalInterFrameDelay"] as? Double
        self.totalSquaredInterFrameDelay = rawValues["totalSquaredInterFrameDelay"] as? Double
        self.pauseCount = rawValues["pauseCount"] as? UInt
        self.totalPausesDuration = rawValues["totalPausesDuration"] as? Double
        self.freezeCount = rawValues["freezeCount"] as? UInt
        self.totalFreezesDuration = rawValues["totalFreezesDuration"] as? Double
        self.lastPacketReceivedTimestamp = rawValues["lastPacketReceivedTimestamp"] as? Double
        self.headerBytesReceived = (rawValues["headerBytesReceived"] as? UInt64) ?? 0
        self.packetsDiscarded = (rawValues["packetsDiscarded"] as? UInt64) ?? 0
        self.fecPacketsReceived = (rawValues["fecPacketsReceived"] as? UInt64) ?? 0
        self.fecPacketsDiscarded = (rawValues["fecPacketsDiscarded"] as? UInt64) ?? 0
        self.bytesReceived = (rawValues["bytesReceived"] as? UInt64) ?? 0
        self.nackCount = rawValues["nackCount"] as? UInt
        self.firCount = rawValues["firCount"] as? UInt
        self.pliCount = rawValues["pliCount"] as? UInt
        self.totalProcessingDelay = rawValues["totalProcessingDelay"] as? Double
        self.estimatedPlayoutTimestamp = rawValues["estimatedPlayoutTimestamp"] as? Double
        self.jitterBufferDelay = rawValues["jitterBufferDelay"] as? Double
        self.jitterBufferTargetDelay = rawValues["jitterBufferTargetDelay"] as? Double
        self.jitterBufferEmittedCount = rawValues["jitterBufferEmittedCount"] as? UInt64
        self.jitterBufferMinimumDelay = rawValues["jitterBufferMinimumDelay"] as? Double
        self.totalSamplesReceived = rawValues["totalSamplesReceived"] as? UInt64
        self.concealedSamples = rawValues["concealedSamples"] as? UInt64
        self.silentConcealedSamples = rawValues["silentConcealedSamples"] as? UInt64
        self.concealmentEvents = rawValues["concealmentEvents"] as? UInt64
        self.insertedSamplesForDeceleration = rawValues["insertedSamplesForDeceleration"] as? UInt64
        self.removedSamplesForAcceleration = rawValues["removedSamplesForAcceleration"] as? UInt64
        self.audioLevel = rawValues["audioLevel"] as? Double
        self.totalAudioEnergy = rawValues["totalAudioEnergy"] as? Double
        self.totalSamplesDuration = rawValues["totalSamplesDuration"] as? Double
        self.framesReceived = rawValues["framesReceived"] as? UInt
        self.decoderImplementation = rawValues["decoderImplementation"] as? String
        self.playoutId = rawValues["playoutId"] as? String
        self.powerEfficientDecoder = rawValues["powerEfficientDecoder"] as? Bool
        self.framesAssembledFromMultiplePackets = rawValues["framesAssembledFromMultiplePackets"] as? UInt
        self.totalAssemblyTime = rawValues["totalAssemblyTime"] as? Double
        self.retransmittedPacketsReceived = rawValues["retransmittedPacketsReceived"] as? UInt64
        self.retransmittedBytesReceived = rawValues["retransmittedBytesReceived"] as? UInt64

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
        self.localId = rawValues["localId"] as? String
        self.roundTripTime = rawValues["roundTripTime"] as? Double
        self.totalRoundTripTime = rawValues["totalRoundTripTime"] as? Double
        self.fractionLost = rawValues["fractionLost"] as? Double
        self.roundTripTimeMeasurements = rawValues["roundTripTimeMeasurements"] as? UInt64

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

        init(rawValues: [String: NSObject]?) {
            self.none = (rawValues?["none"] as? Double) ?? 0.0
            self.cpu = (rawValues?["cpu"] as? Double) ?? 0.0
            self.bandwidth = (rawValues?["bandwidth"] as? Double) ?? 0.0
            self.other = (rawValues?["other"] as? Double) ?? 0.0
        }
    }

    public let mid: String?
    public let mediaSourceId: String?
    public let remoteId: String?
    public let rid: String?
    public let headerBytesSent: UInt64
    public let retransmittedPacketsSent: UInt64
    public let retransmittedBytesSent: UInt64
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
    public let qualityLimitationReason: QualityLimitationReason
    public let qualityLimitationDurations: QualityLimitationDurations
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

        self.mid = rawValues["mid"] as? String
        self.mediaSourceId = rawValues["mediaSourceId"] as? String
        self.remoteId = rawValues["remoteId"] as? String
        self.rid = rawValues["rid"] as? String
        self.headerBytesSent = (rawValues["headerBytesSent"] as? UInt64) ?? 0
        self.retransmittedPacketsSent = (rawValues["retransmittedPacketsSent"] as? UInt64) ?? 0
        self.retransmittedBytesSent = (rawValues["retransmittedBytesSent"] as? UInt64) ?? 0
        self.targetBitrate = rawValues["targetBitrate"] as? Double
        self.totalEncodedBytesTarget = rawValues["totalEncodedBytesTarget"] as? UInt64
        self.frameWidth = rawValues["frameWidth"] as? UInt
        self.frameHeight = rawValues["frameHeight"] as? UInt
        self.framesPerSecond = rawValues["framesPerSecond"] as? Double
        self.framesSent = rawValues["framesSent"] as? UInt
        self.hugeFramesSent = rawValues["hugeFramesSent"] as? UInt
        self.framesEncoded = rawValues["framesEncoded"] as? UInt
        self.keyFramesEncoded = rawValues["keyFramesEncoded"] as? UInt
        self.qpSum = rawValues["qpSum"] as? UInt64
        self.totalEncodeTime = rawValues["totalEncodeTime"] as? Double
        self.totalPacketSendDelay = rawValues["totalPacketSendDelay"] as? Double
        self.qualityLimitationReason = QualityLimitationReason(rawValue: (rawValues["qualityLimitationReason"] as? String) ?? "") ?? .none
        self.qualityLimitationDurations = QualityLimitationDurations(rawValues: rawValues["qualityLimitationDurations"] as? [String: NSObject])
        self.qualityLimitationResolutionChanges = rawValues["qualityLimitationResolutionChanges"] as? UInt
        self.nackCount = rawValues["nackCount"] as? UInt
        self.firCount = rawValues["firCount"] as? UInt
        self.pliCount = rawValues["pliCount"] as? UInt
        self.encoderImplementation = rawValues["encoderImplementation"] as? String
        self.powerEfficientEncoder = rawValues["powerEfficientEncoder"] as? Bool
        self.active = rawValues["active"] as? Bool
        self.scalabilityMode = rawValues["scalabilityMode"] as? String

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

        self.localId = rawValues["localId"] as? String
        self.remoteTimestamp = rawValues["remoteTimestamp"] as? Double
        self.reportsSent = rawValues["reportsSent"] as? UInt64
        self.roundTripTime = rawValues["roundTripTime"] as? Double
        self.totalRoundTripTime = rawValues["totalRoundTripTime"] as? Double
        self.roundTripTimeMeasurements = rawValues["roundTripTimeMeasurements"] as? UInt64

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

        self.audioLevel = rawValues["audioLevel"] as? Double
        self.totalAudioEnergy = rawValues["totalAudioEnergy"] as? Double
        self.totalSamplesDuration = rawValues["totalSamplesDuration"] as? Double
        self.echoReturnLoss = rawValues["echoReturnLoss"] as? Double
        self.echoReturnLossEnhancement = rawValues["echoReturnLossEnhancement"] as? Double
        self.droppedSamplesDuration = rawValues["droppedSamplesDuration"] as? Double
        self.droppedSamplesEvents = rawValues["droppedSamplesEvents"] as? UInt
        self.totalCaptureDelay = rawValues["totalCaptureDelay"] as? Double
        self.totalSamplesCaptured = rawValues["totalSamplesCaptured"] as? UInt64

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

        self.width = rawValues["width"] as? UInt
        self.height = rawValues["height"] as? UInt
        self.frames = rawValues["frames"] as? UInt
        self.framesPerSecond = rawValues["framesPerSecond"] as? Double

        super.init(id: id,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}
