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

internal import LiveKitWebRTC

@objc
public class TrackStatistics: NSObject, @unchecked Sendable, Loggable {
    public let codec: [CodecStatistics]
    public let transportStats: TransportStatistics?
    public let videoSource: [VideoSourceStatistics]

    public let certificate: [CertificateStatistics]
    public let iceCandidatePair: [IceCandidatePairStatistics]

    public let localIceCandidate: LocalIceCandidateStatistics?
    public let remoteIceCandidate: RemoteIceCandidateStatistics?

    public let inboundRtpStream: [InboundRtpStreamStatistics]
    public let outboundRtpStream: [OutboundRtpStreamStatistics]

    public let remoteInboundRtpStream: [RemoteInboundRtpStreamStatistics]
    public let remoteOutboundRtpStream: [RemoteOutboundRtpStreamStatistics]

    init(from stats: [LKRTCStatistics], prevStatistics: TrackStatistics?) {
        let stats = stats.map { $0.toLKType(prevStatistics: prevStatistics) }.compactMap { $0 }

        codec = stats.compactMap { $0 as? CodecStatistics }
        videoSource = stats.compactMap { $0 as? VideoSourceStatistics }
        certificate = stats.compactMap { $0 as? CertificateStatistics }
        iceCandidatePair = stats.compactMap { $0 as? IceCandidatePairStatistics }
        inboundRtpStream = stats.compactMap { $0 as? InboundRtpStreamStatistics }
        outboundRtpStream = stats.compactMap { $0 as? OutboundRtpStreamStatistics }
        remoteInboundRtpStream = stats.compactMap { $0 as? RemoteInboundRtpStreamStatistics }
        remoteOutboundRtpStream = stats.compactMap { $0 as? RemoteOutboundRtpStreamStatistics }

        let transportStatistics = stats.compactMap { $0 as? TransportStatistics }
        transportStats = transportStatistics.first

        let localIceCandidates = stats.compactMap { $0 as? LocalIceCandidateStatistics }
        localIceCandidate = localIceCandidates.first

        let remoteIceCandidates = stats.compactMap { $0 as? RemoteIceCandidateStatistics }
        remoteIceCandidate = remoteIceCandidates.first

        super.init()

        if transportStatistics.count > 1 {
            log("More than 1 TransportStatistics exists", .warning)
        }

        if localIceCandidates.count > 1 {
            log("More than 1 LocalIceCandidateStatistics exists", .warning)
        }

        if remoteIceCandidates.count > 1 {
            log("More than 1 RemoteIceCandidateStatistics exists", .warning)
        }
    }
}

extension LKRTCStatistics {
    func toLKType(prevStatistics: TrackStatistics?) -> Statistics? {
        switch type {
        case "codec": return CodecStatistics(id: id, timestamp: timestamp_us, rawValues: values)
        case "inbound-rtp":
            let previous = prevStatistics?.inboundRtpStream.first(where: { $0.id == id })
            return InboundRtpStreamStatistics(id: id, timestamp: timestamp_us, rawValues: values, previous: previous)
        case "outbound-rtp":
            let previous = prevStatistics?.outboundRtpStream.first(where: { $0.id == id })
            return OutboundRtpStreamStatistics(id: id, timestamp: timestamp_us, rawValues: values, previous: previous)
        case "remote-inbound-rtp": return RemoteInboundRtpStreamStatistics(id: id, timestamp: timestamp_us, rawValues: values)
        case "remote-outbound-rtp": return RemoteOutboundRtpStreamStatistics(id: id, timestamp: timestamp_us, rawValues: values)
        case "media-source":
            guard let mediaSourceStats = MediaSourceStatistics(id: id, timestamp: timestamp_us, rawValues: values) else { return nil }
            if mediaSourceStats.kind == "audio" { return AudioSourceStatistics(id: id, timestamp: timestamp_us, rawValues: values) }
            if mediaSourceStats.kind == "video" { return VideoSourceStatistics(id: id, timestamp: timestamp_us, rawValues: values) }
            return nil
        case "media-playout": return AudioPlayoutStatistics(id: id, timestamp: timestamp_us, rawValues: values)
        case "peer-connection": return PeerConnectionStatistics(id: id, timestamp: timestamp_us, rawValues: values)
        case "data-channel": return DataChannelStatistics(id: id, timestamp: timestamp_us, rawValues: values)
        case "transport": return TransportStatistics(id: id, timestamp: timestamp_us, rawValues: values)
        case "candidate-pair": return IceCandidatePairStatistics(id: id, timestamp: timestamp_us, rawValues: values)
        case "local-candidate": return LocalIceCandidateStatistics(id: id, timestamp: timestamp_us, rawValues: values)
        case "remote-candidate": return RemoteIceCandidateStatistics(id: id, timestamp: timestamp_us, rawValues: values)
        case "certificate": return CertificateStatistics(id: id, timestamp: timestamp_us, rawValues: values)
        default:
            // type: track is not handled
            // print("Unknown stats type: \(type), \(values)")
            return nil
        }
    }
}

public extension TrackStatistics {
    override var description: String {
        "TrackStatistics(inboundRtpStream: \(String(describing: inboundRtpStream)))"
    }
}

extension OutboundRtpStreamStatistics {
    /// Index of the rid.
    var ridIndex: Int {
        guard let rid, let idx = VideoQuality.RIDs.firstIndex(of: rid) else {
            return -1
        }
        return idx
    }
}

public extension Sequence<OutboundRtpStreamStatistics> {
    func sortedByRidIndex() -> [OutboundRtpStreamStatistics] {
        sorted { $0.ridIndex > $1.ridIndex }
    }
}
