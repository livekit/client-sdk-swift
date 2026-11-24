/*
 * Copyright 2026 LiveKit
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

internal import LiveKitFFI
import Foundation

extension TrackStatistics {
    convenience init(native records: [RtcStats], previous: TrackStatistics?) {
        self.init(statistics: records.compactMap { $0.toStatistics(previous: previous) })
    }
}

private extension RtcStats {
    // The generated groups have the same camelCase field names as the existing W3C dictionary
    // decoder. Bridge scalar numbers/maps directly to Foundation; never stringify counters.
    // Exhaustive mapping of the native statistics oneof.
    // swiftlint:disable:next cyclomatic_complexity
    func toStatistics(previous: TrackStatistics?) -> Statistics? {
        guard let stats else { return nil }
        let type: StatisticsType
        let rtc: RtcStatsData
        let groups: [Any]
        switch stats {
        case let .codec(value): (type, rtc, groups) = (.codec, value.rtc, [value.codec])
        case let .inboundRtp(value): (type, rtc, groups) = (.inboundRtp, value.rtc, [value.stream, value.received, value.inbound])
        case let .outboundRtp(value): (type, rtc, groups) = (.outboundRtp, value.rtc, [value.stream, value.sent, value.outbound])
        case let .remoteInboundRtp(value): (type, rtc, groups) = (.remoteInboundRtp, value.rtc, [value.stream, value.received, value.remoteInbound])
        case let .remoteOutboundRtp(value): (type, rtc, groups) = (.remoteOutboundRtp, value.rtc, [value.stream, value.sent, value.remoteOutbound])
        case let .mediaSource(value): (type, rtc, groups) = (.mediaSource, value.rtc, [value.source, value.audio, value.video])
        case let .mediaPlayout(value): (type, rtc, groups) = (.mediaPlayout, value.rtc, [value.audioPlayout])
        case let .peerConnection(value): (type, rtc, groups) = (.peerConnection, value.rtc, [value.pc])
        case let .dataChannel(value): (type, rtc, groups) = (.dataChannel, value.rtc, [value.dc])
        case let .transport(value): (type, rtc, groups) = (.transport, value.rtc, [value.transport])
        case let .candidatePair(value): (type, rtc, groups) = (.candidatePair, value.rtc, [value.candidatePair])
        case let .localCandidate(value): (type, rtc, groups) = (.localCandidate, value.rtc, [value.candidate])
        case let .remoteCandidate(value): (type, rtc, groups) = (.remoteCandidate, value.rtc, [value.candidate])
        case let .certificate(value): (type, rtc, groups) = (.certificate, value.rtc, [value.certificate])
        case .stream, .track: return nil // Not represented by the existing public TrackStatistics.
        @unknown default: return nil
        }
        var values: [String: NSObject] = [:]
        for group in groups {
            for field in Mirror(reflecting: group).children {
                guard let name = field.label else { continue }
                values[name] = field.value as? NSObject
            }
        }
        convertEnums(in: &values, type: type)
        return Statistics.decode(id: rtc.id, type: type.rawValue, timestamp: Double(rtc.timestamp), values: values, prevStatistics: previous)
    }

    func convertEnums(in values: inout [String: NSObject], type: StatisticsType) {
        // Exact discriminants from the pinned stats.proto, not parsing native descriptions.
        let fields = [
            "qualityLimitationReason": ["none", "cpu", "bandwidth", "other"],
            "iceRole": ["unknown", "controlling", "controlled"],
            "dtlsState": ["new", "connecting", "connected", "closed", "failed"],
            "iceState": ["new", "checking", "connected", "completed", "disconnected", "failed", "closed"],
            "dtlsRole": ["client", "server", "unknown"],
            "candidateType": ["host", "srflx", "prflx", "relay"],
            "relayProtocol": ["udp", "tcp", "tls"],
            "tcpType": ["active", "passive", "so"],
            "state": type == .candidatePair ? ["frozen", "waiting", "in-progress", "failed", "succeeded"] : ["connecting", "open", "closing", "closed"],
        ]
        for (name, cases) in fields {
            guard let number = values[name] as? NSNumber else { continue }
            let index = number.intValue
            values[name] = cases.indices.contains(index) ? cases[index] as NSString : nil
        }
    }
}
