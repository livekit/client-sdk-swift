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
public enum StatsType: String {
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
public enum StatsQualityLimitationReason: String {
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
public enum StatsDtlsRole: String {
    /// The RTCPeerConnection is acting as a DTLS client as defined in [RFC6347].
    case client = "client"

    /// The RTCPeerConnection is acting as a DTLS server as defined in [RFC6347].
    case server = "server"

    /// The DTLS role of the RTCPeerConnection has not been determined yet.
    case unknown = "unknown"
}

/// RTCStatsIceCandidatePairState represents the state of the ICE candidate pair as defined in Section 5.7.4 of [RFC5245].
public enum StatsIceCandidatePairState: String {
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

public enum StatsDataChannelState: String {
    case connecting = "connecting"
    case open = "open"
    case closing = "closing"
    case closed = "closed"
}

public enum StatsIceRole: String {
    case unknown = "unknown"
    case controlling = "controlling"
    case controlled = "controlled"
}

public enum StatsDtlsTransportState: String {
    case new = "new"
    case connecting = "connecting"
    case connected = "connected"
    case closed = "closed"
    case failed = "failed"
}

public enum StatsIceTransportState: String {
    case new = "new"
    case checking = "checking"
    case connected = "connected"
    case completed = "completed"
    case disconnected = "disconnected"
    case failed = "failed"
    case closed = "closed"
}

public enum StatsIceCandidateType: String {
    case host = "host"
    case srflx = "srflx"
    case prflx = "prflx"
    case relay = "relay"
}

public enum StatsIceServerTransportProtocol: String {
    case udp = "udp"
    case tcp = "tcp"
    case tls = "tls"
}

public enum StatsIceTcpCandidateType: String {
    case active = "active"
    case passive = "passive"
    case so = "so"
}

// Base class
public class Stats {
    let id: String
    let type: StatsType
    let timestamp: Double

    init?(id: String,
          type: StatsType,
          timestamp: Double) {

        self.id = id
        self.type = type
        self.timestamp = timestamp
    }
}

// type: codec
public class CodecStats: Stats {
    let payloadType: UInt
    let transportId: String
    let mimeType: String
    let clockRate: UInt?
    let channels: UInt?
    let sdpFmtpLine: String?

    init?(id: String,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        guard let payloadType = dictionary["payloadType"] as? UInt,
              let transportId = dictionary["transportId"] as? String,
              let mimeType = dictionary["mimeType"] as? String else { return nil }

        self.payloadType = payloadType
        self.transportId = transportId
        self.mimeType = mimeType
        self.clockRate = dictionary["clockRate"] as? UInt
        self.channels = dictionary["channels"] as? UInt
        self.sdpFmtpLine = dictionary["sdpFmtpLine"] as? String

        super.init(id: id,
                   type: .codec,
                   timestamp: timestamp)
    }
}

public class MediaSourceStats: Stats {

    let trackIdentifier: String
    let kind: String

    init?(id: String,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        guard let trackIdentifier = dictionary["trackIdentifier"] as? String,
              let kind = dictionary["kind"] as? String else { return nil }

        self.trackIdentifier = trackIdentifier
        self.kind = kind

        super.init(id: id,
                   type: .mediaSource,
                   timestamp: timestamp)
    }
}

public class RtpStreamStats: Stats {

    let ssrc: UInt
    let kind: String
    let transportId: String?
    let codecId: String?

    init?(id: String,
          type: StatsType,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        guard let ssrc = dictionary["ssrc"] as? UInt,
              let kind = dictionary["kind"] as? String else { return nil }

        self.ssrc = ssrc
        self.kind = kind
        self.transportId = dictionary["transportId"] as? String
        self.codecId = dictionary["codecId"] as? String

        super.init(id: id,
                   type: type,
                   timestamp: timestamp)
    }
}

// type: media-playout
public class AudioPlayoutStats: Stats {

    let kind: String
    let synthesizedSamplesDuration: Double?
    let synthesizedSamplesEvents: UInt?
    let totalSamplesDuration: Double?
    let totalPlayoutDelay: Double?
    let totalSamplesCount: UInt64?

    init?(id: String,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        guard let kind = dictionary["kind"] as? String else { return nil }

        self.kind = kind
        self.synthesizedSamplesDuration = dictionary["synthesizedSamplesDuration"] as? Double
        self.synthesizedSamplesEvents = dictionary["synthesizedSamplesEvents"] as? UInt
        self.totalSamplesDuration = dictionary["totalSamplesDuration"] as? Double
        self.totalPlayoutDelay = dictionary["totalPlayoutDelay"] as? Double
        self.totalSamplesCount = dictionary["totalSamplesCount"] as? UInt64

        super.init(id: id,
                   type: .mediaPlayout,
                   timestamp: timestamp)
    }
}

// type: peer-connection
public class PeerConnectionStats: Stats {

    let dataChannelsOpened: UInt?
    let dataChannelsClosed: UInt?

    init?(id: String,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        self.dataChannelsOpened = dictionary["dataChannelsOpened"] as? UInt
        self.dataChannelsClosed = dictionary["dataChannelsClosed"] as? UInt

        super.init(id: id,
                   type: .peerConnection,
                   timestamp: timestamp)
    }
}

// type: data-channel
public class RTCDataChannelStats: Stats {

    let label: String?
    let `protocol`: String?
    let dataChannelIdentifier: UInt16?
    let state: StatsDataChannelState?
    let messagesSent: UInt?
    let bytesSent: UInt64?
    let messagesReceived: UInt?
    let bytesReceived: UInt64?

    init?(id: String,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        self.label = dictionary["label"] as? String
        self.protocol = dictionary["protocol"] as? String
        self.dataChannelIdentifier = dictionary["dataChannelIdentifier"] as? UInt16
        self.state = StatsDataChannelState(rawValue: dictionary["state"] as? String ?? "")
        self.messagesSent = dictionary["messagesSent"] as? UInt
        self.bytesSent = dictionary["bytesSent"] as? UInt64
        self.messagesReceived = dictionary["messagesReceived"] as? UInt
        self.bytesReceived = dictionary["bytesReceived"] as? UInt64

        super.init(id: id,
                   type: .dataChannel,
                   timestamp: timestamp)
    }
}

// type: transport
public class RTCTransportStats: Stats {

    let packetsSent: UInt64?
    let packetsReceived: UInt64?
    let bytesSent: UInt64?
    let bytesReceived: UInt64?
    let iceRole: StatsIceRole?
    let iceLocalUsernameFragment: String?
    let dtlsState: StatsDtlsTransportState?
    let iceState: StatsIceTransportState?
    let selectedCandidatePairId: String?
    let localCertificateId: String?
    let remoteCertificateId: String?
    let tlsVersion: String?
    let dtlsCipher: String?
    let dtlsRole: StatsDtlsRole?
    let srtpCipher: String?
    let selectedCandidatePairChanges: UInt?

    init?(id: String,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        self.packetsSent = dictionary["packetsSent"] as? UInt64
        self.packetsReceived = dictionary["packetsReceived"] as? UInt64
        self.bytesSent = dictionary["bytesSent"] as? UInt64
        self.bytesReceived = dictionary["bytesReceived"] as? UInt64
        self.iceRole = StatsIceRole(rawValue: dictionary["iceRole"] as? String ?? "")
        self.iceLocalUsernameFragment = dictionary["iceLocalUsernameFragment"] as? String
        self.dtlsState = StatsDtlsTransportState(rawValue: dictionary["dtlsState"] as? String ?? "")
        self.iceState = StatsIceTransportState(rawValue: dictionary["iceState"] as? String ?? "")
        self.selectedCandidatePairId = dictionary["selectedCandidatePairId"] as? String
        self.localCertificateId = dictionary["localCertificateId"] as? String
        self.remoteCertificateId = dictionary["remoteCertificateId"] as? String
        self.tlsVersion = dictionary["tlsVersion"] as? String
        self.dtlsCipher = dictionary["dtlsCipher"] as? String
        self.dtlsRole = StatsDtlsRole(rawValue: dictionary["dtlsRole"] as? String ?? "")
        self.srtpCipher = dictionary["srtpCipher"] as? String
        self.selectedCandidatePairChanges = dictionary["selectedCandidatePairChanges"] as? UInt

        super.init(id: id,
                   type: .transport,
                   timestamp: timestamp)
    }
}

// type: local-candidate, remote-candidate
public class RTCIceCandidateStats: Stats {

    let transportId: String
    let address: String?
    let port: Int?
    let `protocol`: String?
    let candidateType: StatsIceCandidateType?
    let priority: Int?
    let url: String?
    let relayProtocol: StatsIceServerTransportProtocol?
    let foundation: String?
    let relatedAddress: String?
    let relatedPort: Int?
    let usernameFragment: String?
    let tcpType: StatsIceTcpCandidateType?

    init?(id: String,
          type: StatsType,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        guard let transportId = dictionary["transportId"] as? String else { return nil }

        self.transportId = transportId
        self.address = dictionary["address"] as? String
        self.port = dictionary["port"] as? Int
        self.protocol = dictionary["protocol"] as? String
        self.candidateType = StatsIceCandidateType(rawValue: dictionary["candidateType"] as? String ?? "")
        self.priority = dictionary["priority"] as? Int
        self.url = dictionary["url"] as? String
        self.relayProtocol = StatsIceServerTransportProtocol(rawValue: dictionary["relayProtocol"] as? String ?? "")
        self.foundation = dictionary["foundation"] as? String
        self.relatedAddress = dictionary["relatedAddress"] as? String
        self.relatedPort = dictionary["relatedPort"] as? Int
        self.usernameFragment = dictionary["usernameFragment"] as? String
        self.tcpType = StatsIceTcpCandidateType(rawValue: dictionary["tcpType"] as? String ?? "")

        super.init(id: id,
                   type: type,
                   timestamp: timestamp)
    }
}

public class RTCLocalIceCandidateStats: RTCIceCandidateStats {

    init?(id: String,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        super.init(id: id,
                   type: .localCandidate,
                   timestamp: timestamp,
                   dictionary: dictionary)
    }
}

public class RTCRemoteIceCandidateStats: RTCIceCandidateStats {

    init?(id: String,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        super.init(id: id,
                   type: .remoteCandidate,
                   timestamp: timestamp,
                   dictionary: dictionary)
    }
}

// type: candidate-pair
public class RTCIceCandidatePairStats: Stats {
    let transportId: String
    let localCandidateId: String
    let remoteCandidateId: String
    let state: StatsIceCandidatePairState
    let nominated: Bool?
    let packetsSent: UInt64?
    let packetsReceived: UInt64?
    let bytesSent: UInt64?
    let bytesReceived: UInt64?
    let lastPacketSentTimestamp: Double?
    let lastPacketReceivedTimestamp: Double?
    let totalRoundTripTime: Double?
    let currentRoundTripTime: Double?
    let availableOutgoingBitrate: Double?
    let availableIncomingBitrate: Double?
    let requestsReceived: UInt64?
    let requestsSent: UInt64?
    let responsesReceived: UInt64?
    let responsesSent: UInt64?
    let consentRequestsSent: UInt64?
    let packetsDiscardedOnSend: UInt?
    let bytesDiscardedOnSend: UInt64?

    init?(id: String,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        guard let transportId = dictionary["transportId"] as? String,
              let localCandidateId = dictionary["localCandidateId"] as? String,
              let remoteCandidateId = dictionary["remoteCandidateId"] as? String,
              let state = StatsIceCandidatePairState(rawValue: dictionary["state"] as? String ?? "") else { return nil }

        self.transportId = transportId
        self.localCandidateId = localCandidateId
        self.remoteCandidateId = remoteCandidateId
        self.state = state
        self.nominated = dictionary["nominated"] as? Bool
        self.packetsSent = dictionary["packetsSent"] as? UInt64
        self.packetsReceived = dictionary["packetsReceived"] as? UInt64
        self.bytesSent = dictionary["bytesSent"] as? UInt64
        self.bytesReceived = dictionary["bytesReceived"] as? UInt64
        self.lastPacketSentTimestamp = dictionary["lastPacketSentTimestamp"] as? Double
        self.lastPacketReceivedTimestamp = dictionary["lastPacketReceivedTimestamp"] as? Double
        self.totalRoundTripTime = dictionary["totalRoundTripTime"] as? Double
        self.currentRoundTripTime = dictionary["currentRoundTripTime"] as? Double
        self.availableOutgoingBitrate = dictionary["availableOutgoingBitrate"] as? Double
        self.availableIncomingBitrate = dictionary["availableIncomingBitrate"] as? Double
        self.requestsReceived = dictionary["requestsReceived"] as? UInt64
        self.requestsSent = dictionary["requestsSent"] as? UInt64
        self.responsesReceived = dictionary["responsesReceived"] as? UInt64
        self.responsesSent = dictionary["responsesSent"] as? UInt64
        self.consentRequestsSent = dictionary["consentRequestsSent"] as? UInt64
        self.packetsDiscardedOnSend = dictionary["packetsDiscardedOnSend"] as? UInt
        self.bytesDiscardedOnSend = dictionary["bytesDiscardedOnSend"] as? UInt64

        super.init(id: id,
                   type: .candidatePair,
                   timestamp: timestamp)
    }
}

// type: certificate
public class RTCCertificateStats: Stats {
    let fingerprint: String
    let fingerprintAlgorithm: String
    let base64Certificate: String
    let issuerCertificateId: String?

    init?(id: String,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        guard let fingerprint = dictionary["fingerprint"] as? String,
              let fingerprintAlgorithm = dictionary["fingerprintAlgorithm"] as? String,
              let base64Certificate = dictionary["base64Certificate"] as? String else { return nil }

        self.fingerprint = fingerprint
        self.fingerprintAlgorithm = fingerprintAlgorithm
        self.base64Certificate = base64Certificate
        self.issuerCertificateId = dictionary["issuerCertificateId"] as? String

        super.init(id: id,
                   type: .certificate,
                   timestamp: timestamp)
    }
}

public class RTCReceivedRtpStreamStats: RtpStreamStats {

    let packetsReceived: UInt64?
    let packetsLost: Int64?
    let jitter: Double?

    override init?(id: String,
                   type: StatsType,
                   timestamp: Double,
                   dictionary: [String: NSObject]) {

        self.packetsReceived = dictionary["packetsReceived"] as? UInt64
        self.packetsLost = dictionary["packetsLost"] as? Int64
        self.jitter = dictionary["jitter"] as? Double

        super.init(id: id,
                   type: type,
                   timestamp: timestamp,
                   dictionary: dictionary)
    }
}

public class RTCSentRtpStreamStats: RtpStreamStats {

    let packetsSent: UInt64?
    let bytesSent: UInt64?

    override init?(id: String,
                   type: StatsType,
                   timestamp: Double,
                   dictionary: [String: NSObject]) {

        self.packetsSent = dictionary["packetsSent"] as? UInt64
        self.bytesSent = dictionary["bytesSent"] as? UInt64

        super.init(id: id,
                   type: type,
                   timestamp: timestamp,
                   dictionary: dictionary)
    }
}

// type: inbound-rtp
public class RTCInboundRtpStreamStats: RTCReceivedRtpStreamStats {

    let trackIdentifier: String
    // let kind: String
    let mid: String?
    let remoteId: String?
    let framesDecoded: UInt?
    let keyFramesDecoded: UInt?
    let framesRendered: UInt?
    let framesDropped: UInt?
    let frameWidth: UInt?
    let frameHeight: UInt?
    let framesPerSecond: Double?
    let qpSum: UInt64?
    let totalDecodeTime: Double?
    let totalInterFrameDelay: Double?
    let totalSquaredInterFrameDelay: Double?
    let pauseCount: UInt?
    let totalPausesDuration: Double?
    let freezeCount: UInt?
    let totalFreezesDuration: Double?
    let lastPacketReceivedTimestamp: Double?
    let headerBytesReceived: UInt64?
    let packetsDiscarded: UInt64?
    let fecPacketsReceived: UInt64?
    let fecPacketsDiscarded: UInt64?
    let bytesReceived: UInt64?
    let nackCount: UInt?
    let firCount: UInt?
    let pliCount: UInt?
    let totalProcessingDelay: Double?
    let estimatedPlayoutTimestamp: Double?
    let jitterBufferDelay: Double?
    let jitterBufferTargetDelay: Double?
    let jitterBufferEmittedCount: UInt64?
    let jitterBufferMinimumDelay: Double?
    let totalSamplesReceived: UInt64?
    let concealedSamples: UInt64?
    let silentConcealedSamples: UInt64?
    let concealmentEvents: UInt64?
    let insertedSamplesForDeceleration: UInt64?
    let removedSamplesForAcceleration: UInt64?
    let audioLevel: Double?
    let totalAudioEnergy: Double?
    let totalSamplesDuration: Double?
    let framesReceived: UInt?
    let decoderImplementation: String?
    let playoutId: String?
    let powerEfficientDecoder: Bool?
    let framesAssembledFromMultiplePackets: UInt?
    let totalAssemblyTime: Double?
    let retransmittedPacketsReceived: UInt64?
    let retransmittedBytesReceived: UInt64?

    init?(id: String,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        guard let trackIdentifier = dictionary["trackIdentifier"] as? String else { return nil }

        self.trackIdentifier = trackIdentifier
        // self.kind = kind
        self.mid = dictionary["mid"] as? String
        self.remoteId = dictionary["remoteId"] as? String
        self.framesDecoded = dictionary["framesDecoded"] as? UInt
        self.keyFramesDecoded = dictionary["keyFramesDecoded"] as? UInt
        self.framesRendered = dictionary["framesRendered"] as? UInt
        self.framesDropped = dictionary["framesDropped"] as? UInt
        self.frameWidth = dictionary["frameWidth"] as? UInt
        self.frameHeight = dictionary["frameHeight"] as? UInt
        self.framesPerSecond = dictionary["framesPerSecond"] as? Double
        self.qpSum = dictionary["qpSum"] as? UInt64
        self.totalDecodeTime = dictionary["totalDecodeTime"] as? Double
        self.totalInterFrameDelay = dictionary["totalInterFrameDelay"] as? Double
        self.totalSquaredInterFrameDelay = dictionary["totalSquaredInterFrameDelay"] as? Double
        self.pauseCount = dictionary["pauseCount"] as? UInt
        self.totalPausesDuration = dictionary["totalPausesDuration"] as? Double
        self.freezeCount = dictionary["freezeCount"] as? UInt
        self.totalFreezesDuration = dictionary["totalFreezesDuration"] as? Double
        self.lastPacketReceivedTimestamp = dictionary["lastPacketReceivedTimestamp"] as? Double
        self.headerBytesReceived = dictionary["headerBytesReceived"] as? UInt64
        self.packetsDiscarded = dictionary["packetsDiscarded"] as? UInt64
        self.fecPacketsReceived = dictionary["fecPacketsReceived"] as? UInt64
        self.fecPacketsDiscarded = dictionary["fecPacketsDiscarded"] as? UInt64
        self.bytesReceived = dictionary["bytesReceived"] as? UInt64
        self.nackCount = dictionary["nackCount"] as? UInt
        self.firCount = dictionary["firCount"] as? UInt
        self.pliCount = dictionary["pliCount"] as? UInt
        self.totalProcessingDelay = dictionary["totalProcessingDelay"] as? Double
        self.estimatedPlayoutTimestamp = dictionary["estimatedPlayoutTimestamp"] as? Double
        self.jitterBufferDelay = dictionary["jitterBufferDelay"] as? Double
        self.jitterBufferTargetDelay = dictionary["jitterBufferTargetDelay"] as? Double
        self.jitterBufferEmittedCount = dictionary["jitterBufferEmittedCount"] as? UInt64
        self.jitterBufferMinimumDelay = dictionary["jitterBufferMinimumDelay"] as? Double
        self.totalSamplesReceived = dictionary["totalSamplesReceived"] as? UInt64
        self.concealedSamples = dictionary["concealedSamples"] as? UInt64
        self.silentConcealedSamples = dictionary["silentConcealedSamples"] as? UInt64
        self.concealmentEvents = dictionary["concealmentEvents"] as? UInt64
        self.insertedSamplesForDeceleration = dictionary["insertedSamplesForDeceleration"] as? UInt64
        self.removedSamplesForAcceleration = dictionary["removedSamplesForAcceleration"] as? UInt64
        self.audioLevel = dictionary["audioLevel"] as? Double
        self.totalAudioEnergy = dictionary["totalAudioEnergy"] as? Double
        self.totalSamplesDuration = dictionary["totalSamplesDuration"] as? Double
        self.framesReceived = dictionary["framesReceived"] as? UInt
        self.decoderImplementation = dictionary["decoderImplementation"] as? String
        self.playoutId = dictionary["playoutId"] as? String
        self.powerEfficientDecoder = dictionary["powerEfficientDecoder"] as? Bool
        self.framesAssembledFromMultiplePackets = dictionary["framesAssembledFromMultiplePackets"] as? UInt
        self.totalAssemblyTime = dictionary["totalAssemblyTime"] as? Double
        self.retransmittedPacketsReceived = dictionary["retransmittedPacketsReceived"] as? UInt64
        self.retransmittedBytesReceived = dictionary["retransmittedBytesReceived"] as? UInt64

        super.init(id: id,
                   type: .inboundRtp,
                   timestamp: timestamp,
                   dictionary: dictionary)
    }
}

// type: remote-inbound-rtp
public class RTCRemoteInboundRtpStreamStats: RTCReceivedRtpStreamStats {

    let localId: String?
    let roundTripTime: Double?
    let totalRoundTripTime: Double?
    let fractionLost: Double?
    let roundTripTimeMeasurements: UInt64?

    init?(id: String,
          timestamp: Double,
          dictionary: [String: NSObject]) {
        self.localId = dictionary["localId"] as? String
        self.roundTripTime = dictionary["roundTripTime"] as? Double
        self.totalRoundTripTime = dictionary["totalRoundTripTime"] as? Double
        self.fractionLost = dictionary["fractionLost"] as? Double
        self.roundTripTimeMeasurements = dictionary["roundTripTimeMeasurements"] as? UInt64

        super.init(id: id,
                   type: .remoteInboundRtp,
                   timestamp: timestamp,
                   dictionary: dictionary)
    }
}

// type: outbound-rtp
public class RTCOutboundRtpStreamStats: RTCSentRtpStreamStats {
    let mid: String?
    let mediaSourceId: String?
    let remoteId: String?
    let rid: String?
    let headerBytesSent: UInt64?
    let retransmittedPacketsSent: UInt64?
    let retransmittedBytesSent: UInt64?
    let targetBitrate: Double?
    let totalEncodedBytesTarget: UInt64?
    let frameWidth: UInt?
    let frameHeight: UInt?
    let framesPerSecond: Double?
    let framesSent: UInt?
    let hugeFramesSent: UInt?
    let framesEncoded: UInt?
    let keyFramesEncoded: UInt?
    let qpSum: UInt64?
    let totalEncodeTime: Double?
    let totalPacketSendDelay: Double?
    let qualityLimitationReason: String?
    let qualityLimitationDurations: [String: Double]?
    let qualityLimitationResolutionChanges: UInt?
    let nackCount: UInt?
    let firCount: UInt?
    let pliCount: UInt?
    let encoderImplementation: String?
    let powerEfficientEncoder: Bool?
    let active: Bool?
    let scalabilityMode: String?

    init?(id: String,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        self.mid = dictionary["mid"] as? String
        self.mediaSourceId = dictionary["mediaSourceId"] as? String
        self.remoteId = dictionary["remoteId"] as? String
        self.rid = dictionary["rid"] as? String
        self.headerBytesSent = dictionary["headerBytesSent"] as? UInt64
        self.retransmittedPacketsSent = dictionary["retransmittedPacketsSent"] as? UInt64
        self.retransmittedBytesSent = dictionary["retransmittedBytesSent"] as? UInt64
        self.targetBitrate = dictionary["targetBitrate"] as? Double
        self.totalEncodedBytesTarget = dictionary["totalEncodedBytesTarget"] as? UInt64
        self.frameWidth = dictionary["frameWidth"] as? UInt
        self.frameHeight = dictionary["frameHeight"] as? UInt
        self.framesPerSecond = dictionary["framesPerSecond"] as? Double
        self.framesSent = dictionary["framesSent"] as? UInt
        self.hugeFramesSent = dictionary["hugeFramesSent"] as? UInt
        self.framesEncoded = dictionary["framesEncoded"] as? UInt
        self.keyFramesEncoded = dictionary["keyFramesEncoded"] as? UInt
        self.qpSum = dictionary["qpSum"] as? UInt64
        self.totalEncodeTime = dictionary["totalEncodeTime"] as? Double
        self.totalPacketSendDelay = dictionary["totalPacketSendDelay"] as? Double
        self.qualityLimitationReason = dictionary["qualityLimitationReason"] as? String
        self.qualityLimitationDurations = dictionary["qualityLimitationDurations"] as? [String: Double]
        self.qualityLimitationResolutionChanges = dictionary["qualityLimitationResolutionChanges"] as? UInt
        self.nackCount = dictionary["nackCount"] as? UInt
        self.firCount = dictionary["firCount"] as? UInt
        self.pliCount = dictionary["pliCount"] as? UInt
        self.encoderImplementation = dictionary["encoderImplementation"] as? String
        self.powerEfficientEncoder = dictionary["powerEfficientEncoder"] as? Bool
        self.active = dictionary["active"] as? Bool
        self.scalabilityMode = dictionary["scalabilityMode"] as? String

        super.init(id: id,
                   type: .outboundRtp,
                   timestamp: timestamp,
                   dictionary: dictionary)
    }
}

// type: remote-outbound-rtp
public class RTCRemoteOutboundRtpStreamStats: RTCSentRtpStreamStats {

    let localId: String?
    let remoteTimestamp: Double?
    let reportsSent: UInt64?
    let roundTripTime: Double?
    let totalRoundTripTime: Double?
    let roundTripTimeMeasurements: UInt64?

    init?(id: String,
          timestamp: Double,
          dictionary: [String: NSObject]) {

        self.localId = dictionary["localId"] as? String
        self.remoteTimestamp = dictionary["remoteTimestamp"] as? Double
        self.reportsSent = dictionary["reportsSent"] as? UInt64
        self.roundTripTime = dictionary["roundTripTime"] as? Double
        self.totalRoundTripTime = dictionary["totalRoundTripTime"] as? Double
        self.roundTripTimeMeasurements = dictionary["roundTripTimeMeasurements"] as? UInt64

        super.init(id: id,
                   type: .remoteOutboundRtp,
                   timestamp: timestamp,
                   dictionary: dictionary)
    }
}

public class RTCAudioSourceStats: MediaSourceStats {

    let audioLevel: Double?
    let totalAudioEnergy: Double?
    let totalSamplesDuration: Double?
    let echoReturnLoss: Double?
    let echoReturnLossEnhancement: Double?
    let droppedSamplesDuration: Double?
    let droppedSamplesEvents: UInt?
    let totalCaptureDelay: Double?
    let totalSamplesCaptured: UInt64?

    override init?(id: String,
                   timestamp: Double,
                   dictionary: [String: NSObject]) {

        self.audioLevel = dictionary["audioLevel"] as? Double
        self.totalAudioEnergy = dictionary["totalAudioEnergy"] as? Double
        self.totalSamplesDuration = dictionary["totalSamplesDuration"] as? Double
        self.echoReturnLoss = dictionary["echoReturnLoss"] as? Double
        self.echoReturnLossEnhancement = dictionary["echoReturnLossEnhancement"] as? Double
        self.droppedSamplesDuration = dictionary["droppedSamplesDuration"] as? Double
        self.droppedSamplesEvents = dictionary["droppedSamplesEvents"] as? UInt
        self.totalCaptureDelay = dictionary["totalCaptureDelay"] as? Double
        self.totalSamplesCaptured = dictionary["totalSamplesCaptured"] as? UInt64

        super.init(id: id,
                   timestamp: timestamp,
                   dictionary: dictionary)
    }
}

public class RTCVideoSourceStats: MediaSourceStats {

    let width: UInt?
    let height: UInt?
    let frames: UInt?
    let framesPerSecond: Double?

    override init?(id: String,
                   timestamp: Double,
                   dictionary: [String: NSObject]) {

        self.width = dictionary["width"] as? UInt
        self.height = dictionary["height"] as? UInt
        self.frames = dictionary["frames"] as? UInt
        self.framesPerSecond = dictionary["framesPerSecond"] as? Double

        super.init(id: id,
                   timestamp: timestamp,
                   dictionary: dictionary)
    }
}
