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

import Foundation

/// Direction attribute of a media section (RFC 8866 §6.7).
enum SDPDirection: String {
    case sendrecv, sendonly, recvonly, inactive

    var line: String { "a=" + rawValue }

    init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("a=") else { return nil }
        self.init(rawValue: String(trimmed.dropFirst(2)))
    }
}

/// A parsed `a=rtpmap:<payload> <encoding>` attribute.
struct SDPRtpmap: Equatable {
    let payload: String
    /// Full encoding value, e.g. `opus/48000/2`.
    let encoding: String

    /// Codec name, e.g. `opus`.
    var codec: String { encoding.split(separator: "/").first.map(String.init) ?? encoding }
}

/// A parsed `a=fmtp:<payload> <config>` attribute.
struct SDPFmtp: Equatable {
    let payload: String
    /// Raw config value, e.g. `minptime=10;useinbandfec=1`.
    let config: String

    /// Config split into `;`-separated parameters with surrounding whitespace removed.
    var parameters: [String] {
        config.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// One `m=` section of an SDP document: the `m=` line and every line up to the
/// next `m=` line.
///
/// Lines are stored and written back verbatim — only explicit mutations change
/// them. Typed accessors parse on demand.
struct SDPMediaSection {
    /// All lines of the section; the first is the `m=` line.
    var lines: [String]

    /// Media type from the `m=` line, e.g. `audio`, `video`, `application`.
    var mediaType: String {
        String(mLineParts.first?.dropFirst("m=".count) ?? "")
    }

    /// Whether the section's transport protocol carries RTP (e.g. `UDP/TLS/RTP/SAVPF`),
    /// as opposed to e.g. a data channel's `UDP/DTLS/SCTP`.
    var isRTP: Bool {
        mLineParts.count > 2 && mLineParts[2].contains("RTP/")
    }

    var mid: String? { attributeValue("mid") }

    /// The section's first direction attribute, if any.
    var direction: SDPDirection? {
        lines.dropFirst().lazy.compactMap(SDPDirection.init(line:)).first
    }

    var rtpmaps: [SDPRtpmap] { lines.compactMap(Self.rtpmap(fromLine:)) }

    var fmtps: [SDPFmtp] { lines.compactMap(Self.fmtp(fromLine:)) }

    /// Value of the first `a=<name>:<value>` attribute in the section.
    func attributeValue(_ name: String) -> String? {
        lines.dropFirst().lazy.compactMap { Self.attributeBody($0, name: name) }.first
    }

    /// Payload type mapped to `codec` (case-insensitive) by an `a=rtpmap` line.
    func payload(forCodec codec: String) -> String? {
        rtpmaps.first { $0.codec.caseInsensitiveCompare(codec) == .orderedSame }?.payload
    }

    func fmtp(forPayload payload: String) -> SDPFmtp? {
        fmtps.first { $0.payload == payload }
    }

    /// Replaces the section's direction attribute in place, or appends one if absent.
    mutating func set(direction: SDPDirection) {
        if let index = lines.indices.dropFirst().first(where: { SDPDirection(line: lines[$0]) != nil }) {
            lines[index] = direction.line
        } else {
            lines.append(direction.line)
        }
    }

    /// Appends `parameter` to the fmtp config of `payload`, unless the exact parameter
    /// is already present. Returns `true` if the section was modified; `false` when the
    /// parameter already exists or the section has no fmtp line for `payload` (this
    /// method never inserts a new fmtp line — use ``append(line:)`` for that).
    @discardableResult
    mutating func appendFmtpParameter(_ parameter: String, forPayload payload: String) -> Bool {
        for (index, line) in lines.enumerated() {
            guard let fmtp = Self.fmtp(fromLine: line), fmtp.payload == payload else { continue }
            // Exact-parameter check: a substring test for e.g. "stereo=1" would also
            // match "sprop-stereo=1" and skip the append.
            guard !fmtp.parameters.contains(parameter) else { return false }
            lines[index] = "a=fmtp:\(payload) \(fmtp.config);\(parameter)"
            return true
        }
        return false
    }

    /// Appends a raw line at the end of the section.
    mutating func append(line: String) {
        lines.append(line)
    }

    // MARK: - Private

    private var mLineParts: [Substring] {
        (lines.first ?? "").trimmingCharacters(in: .whitespaces).split(separator: " ")
    }

    private static func rtpmap(fromLine line: String) -> SDPRtpmap? {
        guard let (payload, value) = payloadAttribute(line, name: "rtpmap") else { return nil }
        return SDPRtpmap(payload: payload, encoding: value)
    }

    private static func fmtp(fromLine line: String) -> SDPFmtp? {
        guard let (payload, value) = payloadAttribute(line, name: "fmtp") else { return nil }
        return SDPFmtp(payload: payload, config: value)
    }

    /// Splits an `a=<name>:<payload> <value>` line into payload and value.
    private static func payloadAttribute(_ line: String, name: String) -> (payload: String, value: String)? {
        guard let body = attributeBody(line, name: name),
              let space = body.firstIndex(of: " ") else { return nil }
        let payload = String(body[..<space])
        let value = String(body[body.index(after: space)...])
        guard !payload.isEmpty, !value.isEmpty else { return nil }
        return (payload, value)
    }

    /// Returns the part after `a=<name>:` if `line` is that attribute.
    private static func attributeBody(_ line: String, name: String) -> String? {
        let prefix = "a=\(name):"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { return nil }
        return String(trimmed.dropFirst(prefix.count))
    }
}

/// A lossless, line-oriented model of an SDP document for munging.
///
/// Splits the document into its session-level prelude and `m=` sections while keeping
/// every line verbatim, so `SDP(parsing: sdp).write() == sdp` holds for any
/// input — only explicit mutations change the output. Typed accessors exist solely for
/// the attributes the SDK munges; every other line passes through untouched, which is
/// what makes munging safe against unknown or future SDP attributes.
///
/// This mirrors what sibling SDKs do (`sdp-transform` in client-sdk-js, hand-rolled
/// line edits in rust-sdks) with a stronger round-trip guarantee than sdp-transform,
/// which re-orders attributes on write.
struct SDP {
    /// Lines before the first `m=` line, verbatim.
    var sessionLines: [String]
    var mediaSections: [SDPMediaSection]

    /// Line separator of the source document (`\r\n` per RFC 8866, but lone `\n` and
    /// lone `\r` are tolerated and preserved).
    let eol: String

    private let endsWithEOL: Bool

    init(parsing sdp: String) {
        eol = if sdp.contains("\r\n") {
            "\r\n"
        } else if sdp.contains("\n") {
            "\n"
        } else if sdp.contains("\r") {
            "\r"
        } else {
            "\n"
        }
        var lines = sdp.components(separatedBy: eol)
        if lines.count > 1, lines.last == "" {
            endsWithEOL = true
            lines.removeLast()
        } else {
            endsWithEOL = false
        }

        var sessionLines: [String] = []
        var sections: [SDPMediaSection] = []
        for line in lines {
            if line.hasPrefix("m=") {
                sections.append(SDPMediaSection(lines: [line]))
            } else if sections.isEmpty {
                sessionLines.append(line)
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }
        self.sessionLines = sessionLines
        mediaSections = sections
    }

    func write() -> String {
        var result = (sessionLines + mediaSections.flatMap(\.lines)).joined(separator: eol)
        if endsWithEOL { result += eol }
        return result
    }
}
