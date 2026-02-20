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

@testable import LiveKit
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// Tests for WebRTC Statistics types — parsing raw dictionaries into typed statistics.
class StatisticsTests: LKTestCase {
    // MARK: - StatisticsType raw values

    func testStatisticsTypeRawValues() {
        XCTAssertEqual(StatisticsType.codec.rawValue, "codec")
        XCTAssertEqual(StatisticsType.inboundRtp.rawValue, "inbound-rtp")
        XCTAssertEqual(StatisticsType.outboundRtp.rawValue, "outbound-rtp")
        XCTAssertEqual(StatisticsType.remoteInboundRtp.rawValue, "remote-inbound-rtp")
        XCTAssertEqual(StatisticsType.remoteOutboundRtp.rawValue, "remote-outbound-rtp")
        XCTAssertEqual(StatisticsType.mediaSource.rawValue, "media-source")
        XCTAssertEqual(StatisticsType.mediaPlayout.rawValue, "media-playout")
        XCTAssertEqual(StatisticsType.peerConnection.rawValue, "peer-connection")
        XCTAssertEqual(StatisticsType.dataChannel.rawValue, "data-channel")
        XCTAssertEqual(StatisticsType.transport.rawValue, "transport")
        XCTAssertEqual(StatisticsType.candidatePair.rawValue, "candidate-pair")
        XCTAssertEqual(StatisticsType.localCandidate.rawValue, "local-candidate")
        XCTAssertEqual(StatisticsType.remoteCandidate.rawValue, "remote-candidate")
        XCTAssertEqual(StatisticsType.certificate.rawValue, "certificate")
    }

    // MARK: - Quality / State enums

    func testQualityLimitationReasonRawValues() {
        XCTAssertEqual(QualityLimitationReason.none.rawValue, "none")
        XCTAssertEqual(QualityLimitationReason.cpu.rawValue, "cpu")
        XCTAssertEqual(QualityLimitationReason.bandwidth.rawValue, "bandwidth")
        XCTAssertEqual(QualityLimitationReason.other.rawValue, "other")
    }

    func testDtlsRoleRawValues() {
        XCTAssertEqual(DtlsRole.client.rawValue, "client")
        XCTAssertEqual(DtlsRole.server.rawValue, "server")
        XCTAssertEqual(DtlsRole.unknown.rawValue, "unknown")
    }

    func testIceCandidatePairStateRawValues() {
        XCTAssertEqual(IceCandidatePairState.frozen.rawValue, "frozen")
        XCTAssertEqual(IceCandidatePairState.waiting.rawValue, "waiting")
        XCTAssertEqual(IceCandidatePairState.inProgress.rawValue, "in-progress")
        XCTAssertEqual(IceCandidatePairState.failed.rawValue, "failed")
        XCTAssertEqual(IceCandidatePairState.succeeded.rawValue, "succeeded")
    }

    func testDataChannelStateRawValues() {
        XCTAssertEqual(DataChannelState.connecting.rawValue, "connecting")
        XCTAssertEqual(DataChannelState.open.rawValue, "open")
        XCTAssertEqual(DataChannelState.closing.rawValue, "closing")
        XCTAssertEqual(DataChannelState.closed.rawValue, "closed")
    }

    func testIceRoleRawValues() {
        XCTAssertEqual(IceRole.unknown.rawValue, "unknown")
        XCTAssertEqual(IceRole.controlling.rawValue, "controlling")
        XCTAssertEqual(IceRole.controlled.rawValue, "controlled")
    }

    func testDtlsTransportStateRawValues() {
        XCTAssertEqual(DtlsTransportState.new.rawValue, "new")
        XCTAssertEqual(DtlsTransportState.connecting.rawValue, "connecting")
        XCTAssertEqual(DtlsTransportState.connected.rawValue, "connected")
        XCTAssertEqual(DtlsTransportState.closed.rawValue, "closed")
        XCTAssertEqual(DtlsTransportState.failed.rawValue, "failed")
    }

    func testIceTransportStateRawValues() {
        XCTAssertEqual(IceTransportState.new.rawValue, "new")
        XCTAssertEqual(IceTransportState.checking.rawValue, "checking")
        XCTAssertEqual(IceTransportState.connected.rawValue, "connected")
        XCTAssertEqual(IceTransportState.completed.rawValue, "completed")
        XCTAssertEqual(IceTransportState.disconnected.rawValue, "disconnected")
        XCTAssertEqual(IceTransportState.failed.rawValue, "failed")
        XCTAssertEqual(IceTransportState.closed.rawValue, "closed")
    }

    func testIceCandidateTypeRawValues() {
        XCTAssertEqual(IceCandidateType.host.rawValue, "host")
        XCTAssertEqual(IceCandidateType.srflx.rawValue, "srflx")
        XCTAssertEqual(IceCandidateType.prflx.rawValue, "prflx")
        XCTAssertEqual(IceCandidateType.relay.rawValue, "relay")
    }

    func testIceServerTransportProtocolRawValues() {
        XCTAssertEqual(IceServerTransportProtocol.udp.rawValue, "udp")
        XCTAssertEqual(IceServerTransportProtocol.tcp.rawValue, "tcp")
        XCTAssertEqual(IceServerTransportProtocol.tls.rawValue, "tls")
    }

    func testIceTcpCandidateTypeRawValues() {
        XCTAssertEqual(IceTcpCandidateType.active.rawValue, "active")
        XCTAssertEqual(IceTcpCandidateType.passive.rawValue, "passive")
        XCTAssertEqual(IceTcpCandidateType.so.rawValue, "so")
    }

    // MARK: - CodecStatistics

    func testCodecStatisticsFromRawValues() {
        let raw: [String: NSObject] = [
            "payloadType": NSNumber(value: 111),
            "transportId": "T01" as NSString,
            "mimeType": "audio/opus" as NSString,
            "clockRate": NSNumber(value: 48000),
            "channels": NSNumber(value: 2),
            "sdpFmtpLine": "minptime=10;useinbandfec=1" as NSString,
        ]
        let codec = CodecStatistics(id: "codec-1", timestamp: 1000.0, rawValues: raw)
        XCTAssertNotNil(codec)
        XCTAssertEqual(codec?.id, "codec-1")
        XCTAssertEqual(codec?.type, .codec)
        XCTAssertEqual(codec?.payloadType, 111)
        XCTAssertEqual(codec?.transportId, "T01")
        XCTAssertEqual(codec?.mimeType, "audio/opus")
        XCTAssertEqual(codec?.clockRate, 48000)
        XCTAssertEqual(codec?.channels, 2)
        XCTAssertEqual(codec?.sdpFmtpLine, "minptime=10;useinbandfec=1")
    }

    func testCodecStatisticsWithEmptyRawValues() {
        let codec = CodecStatistics(id: "codec-2", timestamp: 2000.0, rawValues: [:])
        XCTAssertNotNil(codec)
        XCTAssertNil(codec?.payloadType)
        XCTAssertNil(codec?.mimeType)
    }

    // MARK: - PeerConnectionStatistics

    func testPeerConnectionStatistics() {
        let raw: [String: NSObject] = [
            "dataChannelsOpened": NSNumber(value: 3),
            "dataChannelsClosed": NSNumber(value: 1),
        ]
        let pc = PeerConnectionStatistics(id: "pc-1", timestamp: 1000.0, rawValues: raw)
        XCTAssertNotNil(pc)
        XCTAssertEqual(pc?.type, .peerConnection)
        XCTAssertEqual(pc?.dataChannelsOpened, 3)
        XCTAssertEqual(pc?.dataChannelsClosed, 1)
    }

    // MARK: - DataChannelStatistics

    func testDataChannelStatistics() {
        let raw: [String: NSObject] = [
            "label": "reliable" as NSString,
            "protocol": "sctp" as NSString,
            "state": "open" as NSString,
            "messagesSent": NSNumber(value: 42),
            "bytesSent": NSNumber(value: 1024),
            "messagesReceived": NSNumber(value: 10),
            "bytesReceived": NSNumber(value: 512),
        ]
        let dc = DataChannelStatistics(id: "dc-1", timestamp: 1000.0, rawValues: raw)
        XCTAssertNotNil(dc)
        XCTAssertEqual(dc?.type, .dataChannel)
        XCTAssertEqual(dc?.label, "reliable")
        XCTAssertEqual(dc?.state, .open)
        XCTAssertEqual(dc?.messagesSent, 42)
    }

    // MARK: - TransportStatistics

    func testTransportStatistics() {
        let raw: [String: NSObject] = [
            "packetsSent": NSNumber(value: 1000),
            "packetsReceived": NSNumber(value: 900),
            "bytesSent": NSNumber(value: 50000),
            "bytesReceived": NSNumber(value: 45000),
            "iceRole": "controlling" as NSString,
            "dtlsState": "connected" as NSString,
            "iceState": "completed" as NSString,
            "dtlsRole": "client" as NSString,
            "selectedCandidatePairId": "pair-1" as NSString,
            "tlsVersion": "1.3" as NSString,
            "dtlsCipher": "TLS_AES_128_GCM_SHA256" as NSString,
            "srtpCipher": "AES_CM_128_HMAC_SHA1_80" as NSString,
        ]
        let transport = TransportStatistics(id: "transport-1", timestamp: 1000.0, rawValues: raw)
        XCTAssertNotNil(transport)
        XCTAssertEqual(transport?.type, .transport)
        XCTAssertEqual(transport?.iceRole, .controlling)
        XCTAssertEqual(transport?.dtlsState, .connected)
        XCTAssertEqual(transport?.iceState, .completed)
        XCTAssertEqual(transport?.dtlsRole, .client)
        XCTAssertEqual(transport?.packetsSent, 1000)
    }

    // MARK: - IceCandidateStatistics

    func testLocalIceCandidateStatistics() {
        let raw: [String: NSObject] = [
            "transportId": "T01" as NSString,
            "address": "192.168.1.100" as NSString,
            "port": NSNumber(value: 12345),
            "protocol": "udp" as NSString,
            "candidateType": "host" as NSString,
            "priority": NSNumber(value: 2_130_706_431),
            "relayProtocol": "" as NSString,
            "tcpType": "" as NSString,
        ]
        let candidate = LocalIceCandidateStatistics(id: "local-1", timestamp: 1000.0, rawValues: raw)
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.type, .localCandidate)
        XCTAssertEqual(candidate?.address, "192.168.1.100")
        XCTAssertEqual(candidate?.port, 12345)
        XCTAssertEqual(candidate?.candidateType, .host)
    }

    func testRemoteIceCandidateStatistics() {
        let raw: [String: NSObject] = [
            "candidateType": "srflx" as NSString,
            "address": "203.0.113.1" as NSString,
            "relayProtocol": "" as NSString,
            "tcpType": "" as NSString,
        ]
        let candidate = RemoteIceCandidateStatistics(id: "remote-1", timestamp: 1000.0, rawValues: raw)
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.type, .remoteCandidate)
        XCTAssertEqual(candidate?.candidateType, .srflx)
    }

    // MARK: - IceCandidatePairStatistics

    func testIceCandidatePairStatistics() {
        let raw: [String: NSObject] = [
            "transportId": "T01" as NSString,
            "localCandidateId": "local-1" as NSString,
            "remoteCandidateId": "remote-1" as NSString,
            "state": "succeeded" as NSString,
            "nominated": NSNumber(value: true),
            "currentRoundTripTime": NSNumber(value: 0.035),
            "availableOutgoingBitrate": NSNumber(value: 2_500_000.0),
        ]
        let pair = IceCandidatePairStatistics(id: "pair-1", timestamp: 1000.0, rawValues: raw)
        XCTAssertNotNil(pair)
        XCTAssertEqual(pair?.type, .candidatePair)
        XCTAssertEqual(pair?.state, .succeeded)
        XCTAssertEqual(pair?.nominated, true)
        XCTAssertEqual(pair?.currentRoundTripTime, 0.035)
    }

    // MARK: - CertificateStatistics

    func testCertificateStatistics() {
        let raw: [String: NSObject] = [
            "fingerprint": "AB:CD:EF" as NSString,
            "fingerprintAlgorithm": "sha-256" as NSString,
            "base64Certificate": "MIIB..." as NSString,
        ]
        let cert = CertificateStatistics(id: "cert-1", timestamp: 1000.0, rawValues: raw)
        XCTAssertNotNil(cert)
        XCTAssertEqual(cert?.type, .certificate)
        XCTAssertEqual(cert?.fingerprint, "AB:CD:EF")
        XCTAssertEqual(cert?.fingerprintAlgorithm, "sha-256")
    }

    // MARK: - AudioPlayoutStatistics

    func testAudioPlayoutStatistics() {
        let raw: [String: NSObject] = [
            "kind": "audio" as NSString,
            "totalSamplesDuration": NSNumber(value: 10.5),
            "totalPlayoutDelay": NSNumber(value: 0.02),
        ]
        let playout = AudioPlayoutStatistics(id: "playout-1", timestamp: 1000.0, rawValues: raw)
        XCTAssertNotNil(playout)
        XCTAssertEqual(playout?.type, .mediaPlayout)
        XCTAssertEqual(playout?.kind, "audio")
        XCTAssertEqual(playout?.totalSamplesDuration, 10.5)
    }

    // MARK: - MediaSourceStatistics

    func testMediaSourceStatistics() {
        let raw: [String: NSObject] = [
            "trackIdentifier": "track-123" as NSString,
            "kind": "video" as NSString,
        ]
        let source = MediaSourceStatistics(id: "source-1", timestamp: 1000.0, rawValues: raw)
        XCTAssertNotNil(source)
        XCTAssertEqual(source?.type, .mediaSource)
        XCTAssertEqual(source?.kind, "video")
    }

    // MARK: - VideoSourceStatistics

    func testVideoSourceStatistics() {
        let raw: [String: NSObject] = [
            "trackIdentifier": "track-123" as NSString,
            "kind": "video" as NSString,
            "width": NSNumber(value: 1920),
            "height": NSNumber(value: 1080),
            "frames": NSNumber(value: 300),
            "framesPerSecond": NSNumber(value: 30.0),
        ]
        let videoSource = VideoSourceStatistics(id: "source-1", timestamp: 1000.0, rawValues: raw)
        XCTAssertNotNil(videoSource)
        XCTAssertEqual(videoSource?.width, 1920)
        XCTAssertEqual(videoSource?.height, 1080)
        XCTAssertEqual(videoSource?.framesPerSecond, 30.0)
    }

    // MARK: - AudioSourceStatistics

    func testAudioSourceStatistics() {
        let raw: [String: NSObject] = [
            "trackIdentifier": "track-456" as NSString,
            "kind": "audio" as NSString,
            "audioLevel": NSNumber(value: 0.85),
            "totalAudioEnergy": NSNumber(value: 120.5),
        ]
        let audioSource = AudioSourceStatistics(id: "source-2", timestamp: 1000.0, rawValues: raw)
        XCTAssertNotNil(audioSource)
        XCTAssertEqual(audioSource?.audioLevel, 0.85)
        XCTAssertEqual(audioSource?.totalAudioEnergy, 120.5)
    }

    // MARK: - InboundRtpStreamStatistics

    func testInboundRtpStreamStatistics() {
        let raw: [String: NSObject] = [
            "ssrc": NSNumber(value: 123_456),
            "kind": "video" as NSString,
            "trackIdentifier": "track-1" as NSString,
            "mid": "0" as NSString,
            "framesDecoded": NSNumber(value: 1000),
            "framesDropped": NSNumber(value: 5),
            "frameWidth": NSNumber(value: 1920),
            "frameHeight": NSNumber(value: 1080),
            "framesPerSecond": NSNumber(value: 29.97),
            "bytesReceived": NSNumber(value: 5_000_000),
            "jitter": NSNumber(value: 0.003),
        ]
        let inbound = InboundRtpStreamStatistics(id: "inbound-1", timestamp: 1000.0, rawValues: raw, previous: nil)
        XCTAssertNotNil(inbound)
        XCTAssertEqual(inbound?.type, .inboundRtp)
        XCTAssertEqual(inbound?.framesDecoded, 1000)
        XCTAssertEqual(inbound?.frameWidth, 1920)
        XCTAssertEqual(inbound?.framesPerSecond, 29.97)
        XCTAssertNil(inbound?.previous)
    }

    func testInboundRtpStreamWithPrevious() {
        let prevRaw: [String: NSObject] = [
            "ssrc": NSNumber(value: 123_456),
            "kind": "video" as NSString,
            "bytesReceived": NSNumber(value: 3_000_000),
        ]
        let prev = InboundRtpStreamStatistics(id: "inbound-1", timestamp: 500.0, rawValues: prevRaw, previous: nil)

        let raw: [String: NSObject] = [
            "ssrc": NSNumber(value: 123_456),
            "kind": "video" as NSString,
            "bytesReceived": NSNumber(value: 5_000_000),
        ]
        let current = InboundRtpStreamStatistics(id: "inbound-1", timestamp: 1000.0, rawValues: raw, previous: prev)
        XCTAssertNotNil(current)
        XCTAssertNotNil(current?.previous)
        XCTAssertEqual(current?.previous?.bytesReceived, 3_000_000)
    }

    // MARK: - OutboundRtpStreamStatistics

    func testOutboundRtpStreamStatistics() {
        let raw: [String: NSObject] = [
            "ssrc": NSNumber(value: 654_321),
            "kind": "video" as NSString,
            "mid": "1" as NSString,
            "rid": "f" as NSString,
            "packetsSent": NSNumber(value: 500),
            "bytesSent": NSNumber(value: 2_000_000),
            "targetBitrate": NSNumber(value: 1_700_000.0),
            "frameWidth": NSNumber(value: 1280),
            "frameHeight": NSNumber(value: 720),
            "framesPerSecond": NSNumber(value: 30.0),
            "framesEncoded": NSNumber(value: 900),
            "qualityLimitationReason": "none" as NSString,
            "qualityLimitationDurations": [:] as NSDictionary,
            "active": NSNumber(value: true),
            "scalabilityMode": "L1T3" as NSString,
        ]
        let outbound = OutboundRtpStreamStatistics(id: "outbound-1", timestamp: 1000.0, rawValues: raw, previous: nil)
        XCTAssertNotNil(outbound)
        XCTAssertEqual(outbound?.type, .outboundRtp)
        XCTAssertEqual(outbound?.rid, "f")
        XCTAssertEqual(outbound?.targetBitrate, 1_700_000.0)
        XCTAssertEqual(outbound?.qualityLimitationReason, QualityLimitationReason.none)
        XCTAssertEqual(outbound?.active, true)
        XCTAssertEqual(outbound?.scalabilityMode, "L1T3")
    }

    func testOutboundRtpRidIndex() {
        let makeRaw: (String?) -> [String: NSObject] = { rid in
            var raw: [String: NSObject] = ["kind": "video" as NSString]
            if let rid { raw["rid"] = rid as NSString }
            return raw
        }

        let full = OutboundRtpStreamStatistics(id: "o1", timestamp: 0, rawValues: makeRaw("f"), previous: nil)
        XCTAssertEqual(full?.ridIndex, 2) // "f" is index 2 in ["q", "h", "f"]

        let half = OutboundRtpStreamStatistics(id: "o2", timestamp: 0, rawValues: makeRaw("h"), previous: nil)
        XCTAssertEqual(half?.ridIndex, 1)

        let quarter = OutboundRtpStreamStatistics(id: "o3", timestamp: 0, rawValues: makeRaw("q"), previous: nil)
        XCTAssertEqual(quarter?.ridIndex, 0)

        let noRid = OutboundRtpStreamStatistics(id: "o4", timestamp: 0, rawValues: makeRaw(nil), previous: nil)
        XCTAssertEqual(noRid?.ridIndex, -1)
    }

    func testSortedByRidIndex() {
        let makeStats: (String, String?) -> OutboundRtpStreamStatistics? = { id, rid in
            var raw: [String: NSObject] = ["kind": "video" as NSString]
            if let rid { raw["rid"] = rid as NSString }
            return OutboundRtpStreamStatistics(id: id, timestamp: 0, rawValues: raw, previous: nil)
        }

        let stats = [makeStats("q", "q")!, makeStats("h", "h")!, makeStats("f", "f")!]
        let sorted = stats.sortedByRidIndex()

        // sortedByRidIndex sorts descending by ridIndex
        XCTAssertEqual(sorted[0].rid, "f")
        XCTAssertEqual(sorted[1].rid, "h")
        XCTAssertEqual(sorted[2].rid, "q")
    }

    // MARK: - RemoteInboundRtpStreamStatistics

    func testRemoteInboundRtpStreamStatistics() {
        let raw: [String: NSObject] = [
            "ssrc": NSNumber(value: 111),
            "kind": "audio" as NSString,
            "localId": "outbound-1" as NSString,
            "roundTripTime": NSNumber(value: 0.045),
            "totalRoundTripTime": NSNumber(value: 1.35),
            "fractionLost": NSNumber(value: 0.01),
        ]
        let remote = RemoteInboundRtpStreamStatistics(id: "remote-in-1", timestamp: 1000.0, rawValues: raw)
        XCTAssertNotNil(remote)
        XCTAssertEqual(remote?.type, .remoteInboundRtp)
        XCTAssertEqual(remote?.roundTripTime, 0.045)
        XCTAssertEqual(remote?.fractionLost, 0.01)
    }

    // MARK: - RemoteOutboundRtpStreamStatistics

    func testRemoteOutboundRtpStreamStatistics() {
        let raw: [String: NSObject] = [
            "ssrc": NSNumber(value: 222),
            "kind": "video" as NSString,
            "localId": "inbound-1" as NSString,
            "remoteTimestamp": NSNumber(value: 999.5),
            "reportsSent": NSNumber(value: 50),
            "roundTripTime": NSNumber(value: 0.03),
        ]
        let remote = RemoteOutboundRtpStreamStatistics(id: "remote-out-1", timestamp: 1000.0, rawValues: raw)
        XCTAssertNotNil(remote)
        XCTAssertEqual(remote?.type, .remoteOutboundRtp)
        XCTAssertEqual(remote?.remoteTimestamp, 999.5)
    }

    // MARK: - TrackStatistics description

    func testTrackStatisticsDescription() {
        // TrackStatistics requires LKRTCStatistics which is from WebRTC, so we test description format
        // which is public. The description is defined as a computed property.
        // We can at least verify the StatisticsType enum and the Statistics base class.
        let base = Statistics(id: "base-1", type: .codec, timestamp: 1000.0)
        XCTAssertNotNil(base)
        XCTAssertEqual(base?.id, "base-1")
        XCTAssertEqual(base?.type, .codec)
        XCTAssertEqual(base?.timestamp, 1000.0)
    }

    // MARK: - Dictionary readOptional / readNonOptional helpers

    func testReadOptionalReturnsNilForMissingKey() {
        let dict: [String: NSObject] = [:]
        let intVal: Int? = dict.readOptional("missing")
        let strVal: String? = dict.readOptional("missing")
        let dblVal: Double? = dict.readOptional("missing")
        XCTAssertNil(intVal)
        XCTAssertNil(strVal)
        XCTAssertNil(dblVal)
    }

    func testReadNonOptionalReturnsDefaultForMissingKey() {
        let dict: [String: NSObject] = [:]
        let str: String = dict.readNonOptional("missing")
        XCTAssertEqual(str, "")

        let dictVal: [String: NSObject] = dict.readNonOptional("missing")
        XCTAssertTrue(dictVal.isEmpty)
    }
}
