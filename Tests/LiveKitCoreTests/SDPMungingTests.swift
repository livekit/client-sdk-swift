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

class SDPMungingTests: LKTestCase {
    /// All RTP m-sections (audio, video, text) should have `a=inactive` rewritten to `a=recvonly`.
    func testAllRTPSectionsAreMunged() {
        let sdp = [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=mid:0",
            "a=inactive",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=mid:1",
            "a=inactive",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=mid:2",
            "a=inactive",
            "m=text 9 RTP/AVP 98",
            "a=mid:3",
            "a=inactive",
            "",
        ].joined(separator: "\r\n")

        let result = Transport.mungeInactiveToRecvOnlyForMedia(sdp)

        // All four RTP sections should be munged
        XCTAssertFalse(result.contains("a=inactive"), "All a=inactive lines in RTP sections should be rewritten")

        let recvOnlyCount = result.components(separatedBy: "a=recvonly").count - 1
        XCTAssertEqual(recvOnlyCount, 4, "Should have 4 a=recvonly lines (2 audio + 1 video + 1 text)")
    }

    /// `m=application` sections (data channels) should NOT be munged.
    func testApplicationSectionNotMunged() {
        let sdp = [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=mid:0",
            "a=inactive",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
            "a=mid:1",
            "a=inactive",
            "",
        ].joined(separator: "\r\n")

        let result = Transport.mungeInactiveToRecvOnlyForMedia(sdp)

        // Audio section should be munged
        XCTAssertTrue(result.contains("a=recvonly"), "Audio section a=inactive should become a=recvonly")

        // Application section should still have a=inactive
        let lines = result.components(separatedBy: "\r\n")
        let appSectionStart = lines.firstIndex(where: { $0.hasPrefix("m=application") })!
        let inactiveAfterApp = lines[appSectionStart...].contains("a=inactive")
        XCTAssertTrue(inactiveAfterApp, "Application section should preserve a=inactive")
    }

    /// SDP without any `a=inactive` lines should pass through unchanged.
    func testNoOpWhenNoInactiveLines() {
        let sdp = [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=mid:0",
            "a=sendrecv",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=mid:1",
            "a=recvonly",
            "",
        ].joined(separator: "\r\n")

        let result = Transport.mungeInactiveToRecvOnlyForMedia(sdp)

        XCTAssertEqual(result, sdp, "SDP without a=inactive should pass through unchanged")
    }
}
