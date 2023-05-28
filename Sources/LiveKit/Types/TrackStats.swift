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

public extension Double {

    func rounded(to places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

public extension TrackStats {

    private static let bpsDivider: Double = 1000

    private func format(bps: Int) -> String {

        let ordinals = ["", "K", "M", "G", "T", "P", "E"]

        var rate = Double(bps)
        var ordinal = 0

        while rate > Self.bpsDivider {
            rate /= Self.bpsDivider
            ordinal += 1
        }

        return String(rate.rounded(to: 2)) + ordinals[ordinal] + "bps"
    }

    func formattedBpsSent() -> String {
        format(bps: bpsSent)
    }

    func formattedBpsReceived() -> String {
        format(bps: bpsReceived)
    }
}

@objc
public class TrackStats: NSObject {

    // MARK: - Equal

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return  self.created == other.created &&
            self.ssrc == other.ssrc &&
            self.trackId == other.trackId  &&
            self.bytesSent == other.bytesSent &&
            self.bytesReceived == other.bytesReceived &&
            self.codecName == other.codecName &&
            self.bpsSent == other.bpsSent &&
            self.bpsReceived == other.bpsReceived
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(created)
        hasher.combine(ssrc)
        hasher.combine(trackId)
        hasher.combine(bytesSent)
        hasher.combine(bytesReceived)
        hasher.combine(codecName)
        hasher.combine(bpsSent)
        hasher.combine(bpsReceived)
        return hasher.finalize()
    }

    static let keyTypeSSRC = "ssrc"
    static let keyTrackId = "googTrackId"

    static let keyBytesSent = "bytesSent"
    static let keyBytesReceived = "bytesReceived"
    static let keyLastDate = "lastDate"
    static let keyMediaTypeKey = "mediaType"
    static let keyCodecName = "googCodecName"

    // date and time of this stats created
    public let created = Date()

    public let ssrc: String
    public let trackId: String

    // TODO: add more values
    public let bytesSent: Int
    public let bytesReceived: Int
    public let codecName: String?

    public let bpsSent: Int
    public let bpsReceived: Int

    // video
    // "googCpuLimitedResolution": "false",
    // "hugeFramesSent": "0",
    // "googRtt": "0",
    // "mediaType": "video",
    // "googAdaptationChanges": "0",
    // "googEncodeUsagePercent": "0",
    // "googFrameHeightInput": "450",
    // "googTrackId": "B6D8300D-53AC-4C10-A9AC-4403CE1EE7E0",
    // "ssrc": "2443805324",
    // "googBandwidthLimitedResolution": "false",
    // "googContentType": "realtime",
    // "googFrameHeightSent": "112",
    // "codecImplementationName": "SimulcastEncoderAdapter (libvpx, libvpx)",
    // "framesEncoded": "1",
    // "bytesSent": "44417",
    // "googCodecName": "VP8",
    // "packetsSent": "181",
    // "googPlisReceived": "0",
    // "packetsLost": "0",
    // "googAvgEncodeMs": "0",
    // "googFirsReceived": "0",
    // "googNacksReceived": "0",
    // "qpSum": "86",
    // "transportId": "Channel-0-1",
    // "googHasEnteredLowResolution": "false",
    // "googFrameRateSent": "1",
    // "googFrameWidthInput": "800",
    // "googFrameWidthSent": "200",
    // "googFrameRateInput": "1"

    init?(from values: [String: String], previous: TrackStats?) {

        // ssrc is required
        guard let ssrc = values[TrackStats.keyTypeSSRC],
              let trackId = values[TrackStats.keyTrackId]  else {
            return nil
        }

        self.ssrc = ssrc
        self.trackId = trackId
        self.bytesSent = Int(values[TrackStats.keyBytesSent] ?? "0") ?? 0
        self.bytesReceived = Int(values[TrackStats.keyBytesReceived] ?? "0") ?? 0
        self.codecName = values[TrackStats.keyCodecName] as String?

        if let previous = previous {
            let secondsDiff = self.created.timeIntervalSince(previous.created)
            self.bpsSent = Int(Double(((self.bytesSent - previous.bytesSent) * 8)) / abs(secondsDiff))
            self.bpsReceived = Int(Double(((self.bytesReceived - previous.bytesReceived) * 8)) / abs(secondsDiff))
        } else {
            self.bpsSent = 0
            self.bpsReceived = 0
        }
    }
}
//
///// Base class for outbound-rtp stats
// class OutboundRTPStreamStats {
//
//    let bytesSent: Int
//    let codecId: String
//    let headerBytesSent: Int
//    let kind: String
//    let mediaSourceId: String
//    let mediaType: String
//    let nackCount: Int
//    let packetsSent: Int
//    let retransmittedBytesSent: Int
//    let retransmittedPacketsSent: Int
//    let ssrc: Int
//    let trackId: String
//    let transportId: String
//
//    init?(from values: [String: NSObject]) {
//        self.bytesSent = (values["bytesSent"] as? Int) ?? 0
//        self.codecId = (values["codecId"] as? String) ?? ""
//        self.headerBytesSent = (values["headerBytesSent"] as? Int) ?? 0
//        self.kind = (values["kind"] as? String) ?? ""
//        self.mediaSourceId = (values["mediaSourceId"] as? String) ?? ""
//        self.mediaType = (values["mediaType"] as? String) ?? ""
//        self.nackCount = (values["nackCount"] as? Int) ?? 0
//        self.packetsSent = (values["packetsSent"] as? Int) ?? 0
//        self.retransmittedBytesSent = (values["retransmittedBytesSent"] as? Int) ?? 0
//        self.retransmittedPacketsSent = (values["retransmittedPacketsSent"] as? Int) ?? 0
//        self.ssrc = (values["ssrc"] as? Int) ?? 0
//        self.trackId = (values["trackId"] as? String) ?? ""
//        self.transportId = (values["transportId"] as? String) ?? ""
//    }
// }
//
// class OutboundRTPAudioStreamStats: OutboundRTPStreamStats {
//
//    let remoteId: String
//    let targetBitrate: Int
//
//    override init?(from values: [String: NSObject]) {
//
//        self.remoteId = (values["remoteId"] as? String) ?? ""
//        self.targetBitrate = (values["targetBitrate"] as? Int) ?? 0
//
//        super.init(from: values)
//    }
// }

// class OutboundRTPVideoStreamStats: OutboundRTPStreamStats {
//
//    let encoderImplementation: String
//    let firCount: Int
//    let framesEncoded: Int
//    let framesSent: Int
//    let hugeFramesSent: Int
//    let keyFramesEncoded: Int
//    let pliCount: Int
//    let qualityLimitationDurations: QualityLimitationDurationsStats
//    let qualityLimitationReason: String
//    let qualityLimitationResolutionChanges: Int
//    let rid: String
//    let totalEncodedBytesTarget: Int
//    let totalEncodeTime: Int
//    let totalPacketSendDelay: Int
//
//    override init?(from values: [String: NSObject]) {
//
//        self.encoderImplementation = (values["encoderImplementation"] as? String) ?? ""
//        self.firCount = (values["firCount"] as? Int) ?? 0
//        self.framesEncoded = (values["framesEncoded"] as? Int) ?? 0
//        self.framesSent = (values["framesSent"] as? Int) ?? 0
//        self.hugeFramesSent = (values["hugeFramesSent"] as? Int) ?? 0
//        self.keyFramesEncoded = (values["keyFramesEncoded"] as? Int) ?? 0
//        self.pliCount = (values["pliCount"] as? Int) ?? 0
//        self.qualityLimitationDurations = QualityLimitationDurationsStats(from: values["qualityLimitationDurations"] as? [String: NSObject])
//        self.qualityLimitationReason = (values["qualityLimitationReason"] as? String) ?? ""
//        self.qualityLimitationResolutionChanges = (values["qualityLimitationResolutionChanges"] as? Int) ?? 0
//        self.rid = (values["rid"] as? String) ?? ""
//        self.totalEncodeTime = (values["totalEncodeTime"] as? Int) ?? 0
//        self.totalPacketSendDelay = (values["totalPacketSendDelay"] as? Int) ?? 0
//
//        super.init(from: values)
//    }
// }
//
// struct QualityLimitationDurationsStats {
//
//    let bandwidth: Double
//    let cpu: Double
//    let none: Double
//    let other: Double
//
//    init(from values: [String: NSObject]?) {
//        self.bandwidth = (values?["bandwidth"] as? Double) ?? 0.0
//        self.cpu = (values?["cpu"] as? Double) ?? 0.0
//        self.none = (values?["none"] as? Double) ?? 0.0
//        self.other = (values?["other"] as? Double) ?? 0.0
//    }
// }
//
///// https://www.w3.org/TR/webrtc-stats/#dom-rtcstatsicecandidatepairstate
// enum RTCStatsIceCandidatePairState: String {
//    case frozen
//    case waiting
//    case inProgress = "in-progress"
//    case failed
//    case succeeded
// }
//
///// https://www.w3.org/TR/webrtc-stats/#candidatepair-dict*
// struct IceCandidatePairStats {
//
//    let transportId: String
//    let localCandidateId: String
//    let remoteCandidateId: String
//    let state: RTCStatsIceCandidatePairState
//
//    let nominated: Bool
//    let packetsSent: UInt64
//    let packetsReceived: UInt64
//    let bytesSent: UInt64
//    let bytesReceived: UInt64
//
//    // DOMHighResTimeStamp lastPacketSentTimestamp;
//    // DOMHighResTimeStamp lastPacketReceivedTimestamp;
//    let totalRoundTripTime: Double
//    let currentRoundTripTime: Double
//    let availableOutgoingBitrate: Double
//    let availableIncomingBitrate: Double
//    let requestsReceived: UInt64
//    let requestsSent: UInt64
//    let responsesReceived: UInt64
//    let responsesSent: UInt64
//    let consentRequestsSent: UInt64
//    let packetsDiscardedOnSend: UInt32
//    let bytesDiscardedOnSend: UInt64
// }
