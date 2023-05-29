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
    let rawValues: [String: NSObject]

    init?(id: String,
          type: StatsType,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.rawValues = rawValues
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

public class MediaSourceStats: Stats {

    let trackIdentifier: String
    let kind: String

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

public class RtpStreamStats: Stats {

    let ssrc: UInt
    let kind: String
    let transportId: String?
    let codecId: String?

    override init?(id: String,
                   type: StatsType,
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
public class AudioPlayoutStats: Stats {

    let kind: String
    let synthesizedSamplesDuration: Double?
    let synthesizedSamplesEvents: UInt?
    let totalSamplesDuration: Double?
    let totalPlayoutDelay: Double?
    let totalSamplesCount: UInt64?

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
public class PeerConnectionStats: Stats {

    let dataChannelsOpened: UInt?
    let dataChannelsClosed: UInt?

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
          rawValues: [String: NSObject]) {

        self.label = rawValues["label"] as? String
        self.protocol = rawValues["protocol"] as? String
        self.dataChannelIdentifier = rawValues["dataChannelIdentifier"] as? UInt16
        self.state = StatsDataChannelState(rawValue: rawValues["state"] as? String ?? "")
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
          rawValues: [String: NSObject]) {

        self.packetsSent = rawValues["packetsSent"] as? UInt64
        self.packetsReceived = rawValues["packetsReceived"] as? UInt64
        self.bytesSent = rawValues["bytesSent"] as? UInt64
        self.bytesReceived = rawValues["bytesReceived"] as? UInt64
        self.iceRole = StatsIceRole(rawValue: rawValues["iceRole"] as? String ?? "")
        self.iceLocalUsernameFragment = rawValues["iceLocalUsernameFragment"] as? String
        self.dtlsState = StatsDtlsTransportState(rawValue: rawValues["dtlsState"] as? String ?? "")
        self.iceState = StatsIceTransportState(rawValue: rawValues["iceState"] as? String ?? "")
        self.selectedCandidatePairId = rawValues["selectedCandidatePairId"] as? String
        self.localCertificateId = rawValues["localCertificateId"] as? String
        self.remoteCertificateId = rawValues["remoteCertificateId"] as? String
        self.tlsVersion = rawValues["tlsVersion"] as? String
        self.dtlsCipher = rawValues["dtlsCipher"] as? String
        self.dtlsRole = StatsDtlsRole(rawValue: rawValues["dtlsRole"] as? String ?? "")
        self.srtpCipher = rawValues["srtpCipher"] as? String
        self.selectedCandidatePairChanges = rawValues["selectedCandidatePairChanges"] as? UInt

        super.init(id: id,
                   type: .transport,
                   timestamp: timestamp,
                   rawValues: rawValues)
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

    override init?(id: String,
                   type: StatsType,
                   timestamp: Double,
                   rawValues: [String: NSObject]) {

        guard let transportId = rawValues["transportId"] as? String else { return nil }

        self.transportId = transportId
        self.address = rawValues["address"] as? String
        self.port = rawValues["port"] as? Int
        self.protocol = rawValues["protocol"] as? String
        self.candidateType = StatsIceCandidateType(rawValue: rawValues["candidateType"] as? String ?? "")
        self.priority = rawValues["priority"] as? Int
        self.url = rawValues["url"] as? String
        self.relayProtocol = StatsIceServerTransportProtocol(rawValue: rawValues["relayProtocol"] as? String ?? "")
        self.foundation = rawValues["foundation"] as? String
        self.relatedAddress = rawValues["relatedAddress"] as? String
        self.relatedPort = rawValues["relatedPort"] as? Int
        self.usernameFragment = rawValues["usernameFragment"] as? String
        self.tcpType = StatsIceTcpCandidateType(rawValue: rawValues["tcpType"] as? String ?? "")

        super.init(id: id,
                   type: type,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

public class RTCLocalIceCandidateStats: RTCIceCandidateStats {

    init?(id: String,
          timestamp: Double,
          rawValues: [String: NSObject]) {

        super.init(id: id,
                   type: .localCandidate,
                   timestamp: timestamp,
                   rawValues: rawValues)
    }
}

public class RTCRemoteIceCandidateStats: RTCIceCandidateStats {

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
          rawValues: [String: NSObject]) {

        guard let transportId = rawValues["transportId"] as? String,
              let localCandidateId = rawValues["localCandidateId"] as? String,
              let remoteCandidateId = rawValues["remoteCandidateId"] as? String,
              let state = StatsIceCandidatePairState(rawValue: rawValues["state"] as? String ?? "") else { return nil }

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
public class RTCCertificateStats: Stats {
    let fingerprint: String
    let fingerprintAlgorithm: String
    let base64Certificate: String
    let issuerCertificateId: String?

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

public class RTCReceivedRtpStreamStats: RtpStreamStats {

    let packetsReceived: UInt64?
    let packetsLost: Int64?
    let jitter: Double?

    override init?(id: String,
                   type: StatsType,
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

public class RTCSentRtpStreamStats: RtpStreamStats {

    let packetsSent: UInt64?
    let bytesSent: UInt64?

    override init?(id: String,
                   type: StatsType,
                   timestamp: Double,
                   rawValues: [String: NSObject]) {

        self.packetsSent = rawValues["packetsSent"] as? UInt64
        self.bytesSent = rawValues["bytesSent"] as? UInt64

        super.init(id: id,
                   type: type,
                   timestamp: timestamp,
                   rawValues: rawValues)
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
          rawValues: [String: NSObject]) {

        guard let trackIdentifier = rawValues["trackIdentifier"] as? String else { return nil }

        self.trackIdentifier = trackIdentifier
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
        self.headerBytesReceived = rawValues["headerBytesReceived"] as? UInt64
        self.packetsDiscarded = rawValues["packetsDiscarded"] as? UInt64
        self.fecPacketsReceived = rawValues["fecPacketsReceived"] as? UInt64
        self.fecPacketsDiscarded = rawValues["fecPacketsDiscarded"] as? UInt64
        self.bytesReceived = rawValues["bytesReceived"] as? UInt64
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

        super.init(id: id,
                   type: .inboundRtp,
                   timestamp: timestamp,
                   rawValues: rawValues)
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
          rawValues: [String: NSObject]) {

        self.mid = rawValues["mid"] as? String
        self.mediaSourceId = rawValues["mediaSourceId"] as? String
        self.remoteId = rawValues["remoteId"] as? String
        self.rid = rawValues["rid"] as? String
        self.headerBytesSent = rawValues["headerBytesSent"] as? UInt64
        self.retransmittedPacketsSent = rawValues["retransmittedPacketsSent"] as? UInt64
        self.retransmittedBytesSent = rawValues["retransmittedBytesSent"] as? UInt64
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
        self.qualityLimitationReason = rawValues["qualityLimitationReason"] as? String
        self.qualityLimitationDurations = rawValues["qualityLimitationDurations"] as? [String: Double]
        self.qualityLimitationResolutionChanges = rawValues["qualityLimitationResolutionChanges"] as? UInt
        self.nackCount = rawValues["nackCount"] as? UInt
        self.firCount = rawValues["firCount"] as? UInt
        self.pliCount = rawValues["pliCount"] as? UInt
        self.encoderImplementation = rawValues["encoderImplementation"] as? String
        self.powerEfficientEncoder = rawValues["powerEfficientEncoder"] as? Bool
        self.active = rawValues["active"] as? Bool
        self.scalabilityMode = rawValues["scalabilityMode"] as? String

        super.init(id: id,
                   type: .outboundRtp,
                   timestamp: timestamp,
                   rawValues: rawValues)
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

public class RTCVideoSourceStats: MediaSourceStats {

    let width: UInt?
    let height: UInt?
    let frames: UInt?
    let framesPerSecond: Double?

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
