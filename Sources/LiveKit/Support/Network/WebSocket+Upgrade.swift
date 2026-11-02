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

internal import CryptoKit
import Foundation
import Network

/// The server answered the upgrade request with an HTTP response instead of switching
/// protocols. Carried as the `internalError` of the thrown ``LiveKitError``.
struct WebSocketUpgradeFailure: Error, Sendable {
    let statusCode: Int
}

extension WebSocket {
    /// The most the head of the upgrade response may take.
    static let upgradeResponseLimit = 1 << 14

    /// A fresh `Sec-WebSocket-Key`.
    static func upgradeKey() -> String {
        Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
    }

    /// The upgrade request with `headers`, the ``upgradeHeaders(url:headers:)``, `Host` included.
    static func upgradeRequest(url: URL, key: String, headers: [(name: String, value: String)]) throws -> Data {
        // The request target as URLSession sent it: escaped, as `URL.path` would not give it.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? ""
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery { target += "?\(query)" }
        var request = "GET \(target) HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n"
        for (name, value) in headers {
            // A line break would end the header and start one that the caller did not write.
            guard !(name + value).contains(where: \.isNewline) else {
                throw LiveKitError(.invalidParameter, message: "Header \(name) contains a line break")
            }
            request += "\(name): \(value)\r\n"
        }
        return Data((request + "\r\n").utf8)
    }

    /// What the bytes read so far make of the upgrade.
    struct UpgradeResponse: Sendable {
        let rest: Data
        let compression: WebSocketCompression?
    }

    enum UpgradeOutcome {
        /// The final response head is not whole yet.
        case incomplete
        /// The socket opens, with the bytes after the final head: they can hold the first frames.
        case opened(UpgradeResponse)
        case failed(LiveKitError)
    }

    /// Reads the answer to the upgrade request, at most ``upgradeResponseLimit`` bytes for every head it holds, and
    /// resumes `opening` once ``upgradeOutcome(_:key:)`` settles it.
    static func readUpgradeResponse(_ connection: NWConnection, url: URL, key: String, compressionOffered: Bool,
                                    into opening: AsyncCompleter<UpgradeResponse>, read: Data = Data())
    {
        connection.receive(minimumIncompleteLength: 1, maximumLength: upgradeResponseLimit - read.count) { content, _, isComplete, error in
            let read = read + (content ?? Data())
            switch upgradeOutcome(read, key: key, url: url, compressionOffered: compressionOffered) {
            case let .opened(rest):
                opening.resume(returning: rest)
            case let .failed(failure):
                opening.resume(throwing: failure)
            case .incomplete:
                if let error { return opening.resume(throwing: error) }
                guard !isComplete, read.count < upgradeResponseLimit else {
                    return opening.resume(throwing: badUpgradeResponse("no whole head in \(read.count) bytes"))
                }
                readUpgradeResponse(connection, url: url, key: key, compressionOffered: compressionOffered, into: opening, read: read)
            }
        }
    }

    /// What `read` makes of the upgrade. Interim heads (`100 Continue`) are skipped, as SwiftNIO's HTTP decoder does. A
    /// final status other than 101, in any HTTP/1.x, reaches the caller as a ``WebSocketUpgradeFailure``; a 101 must be
    /// HTTP/1.1 or later and switch protocols as RFC 6455 §4.1 asks.
    static func upgradeOutcome(_ read: Data, key: String, url: URL? = nil, compressionOffered: Bool = true) -> UpgradeOutcome {
        var rest = read[...]
        while let end = rest.range(of: Data("\r\n\r\n".utf8)) {
            let lines = String(bytes: rest[..<end.lowerBound], encoding: .isoLatin1)?.components(separatedBy: "\r\n") ?? []
            rest = rest[end.upperBound...]
            guard let (minor, status) = lines.first.flatMap(statusLine) else {
                return .failed(badUpgradeResponse("a malformed status line"))
            }
            if (100 ..< 200).contains(status), status != 101 { continue }
            let fields = fields(of: lines.dropFirst())
            if let url, let fields { storeCookies(fields, for: url) }
            guard status == 101 else {
                return .failed(LiveKitError(.network, internalError: WebSocketUpgradeFailure(statusCode: status)))
            }
            guard minor >= 1 else { return .failed(badUpgradeResponse("a 101 in HTTP/1.0")) }
            if let failure = switchingFailure(fields, key: key) { return .failed(failure) }
            do {
                let compression = try WebSocketCompression.negotiate(fields?.filter { $0.name == "sec-websocket-extensions" }.map(\.value) ?? [])
                guard compression == nil || compressionOffered else { return .failed(badUpgradeResponse("an unsolicited extension")) }
                return .opened(UpgradeResponse(rest: Data(rest), compression: compression))
            } catch {
                return .failed(badUpgradeResponse("invalid compression parameters"))
            }
        }
        return .incomplete
    }

    /// The minor version and the status of an HTTP/1.x status line, "HTTP/1.1 101 Switching Protocols". Any minor
    /// version counts, as in SwiftNIO's HTTP decoder: a rejection in HTTP/1.0 keeps its status.
    private static func statusLine(_ line: String) -> (minor: Int, status: Int)? {
        func digits(_ text: Substring) -> Int? {
            text.allSatisfy { ("0" ... "9").contains($0) } ? Int(text) : nil
        }
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard let version = parts.first, version.count == 8, version.hasPrefix("HTTP/1."),
              let minor = digits(version.suffix(1)),
              let code = parts.dropFirst().first, code.count == 3, let status = digits(code) else { return nil }
        return (minor, status)
    }

    /// The header fields, names lowercased; nil when a line is not a field.
    private static func fields(of lines: ArraySlice<String>) -> [(name: String, value: String)]? {
        var fields: [(name: String, value: String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line[..<colon].contains(where: \.isWhitespace) else { return nil }
            fields.append((line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return fields
    }

    /// What keeps a 101 response from opening the socket (RFC 6455 §4.1): it needs `Upgrade: websocket`, a
    /// `Connection` with the `upgrade` token, and exactly one `Sec-WebSocket-Accept` that answers `key`. It must name no
    /// subprotocol, because the request asked for none. Compression parameters are checked separately.
    private static func switchingFailure(_ fields: [(name: String, value: String)]?, key: String) -> LiveKitError? {
        guard let fields else { return badUpgradeResponse("a malformed header field") }
        func values(_ name: String) -> [String] { fields.filter { $0.name == name }.map(\.value) }
        guard values("upgrade").map({ $0.lowercased() }) == ["websocket"] else {
            return badUpgradeResponse("no Upgrade: websocket")
        }
        let connection = values("connection").flatMap { $0.split(separator: ",") }
        guard connection.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "upgrade" }) else {
            return badUpgradeResponse("no upgrade token in Connection")
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        guard values("sec-websocket-accept") == [accept] else {
            return badUpgradeResponse("not exactly one Sec-WebSocket-Accept that answers the key")
        }
        guard values("sec-websocket-protocol").isEmpty else {
            return badUpgradeResponse("a subprotocol that was not asked for")
        }
        return nil
    }

    private static func badUpgradeResponse(_ reason: String) -> LiveKitError {
        LiveKitError(.network, message: "WebSocket upgrade response: \(reason)", internalError: URLError(.badServerResponse))
    }

    /// Cookie matching uses HTTP schemes, including HTTPS for secure cookies on a WSS connection.
    private static func cookieURL(_ url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = url.scheme == "wss" ? "https" : "http"
        return components?.url
    }

    /// A final HTTP response can set cookies even when it rejects the upgrade. Keep separate Set-Cookie fields
    /// separate: an Expires date can contain a comma. Storage policy still belongs to Foundation.
    private static func storeCookies(_ fields: [(name: String, value: String)], for url: URL) {
        guard let url = cookieURL(url) else { return }
        let cookies = fields.filter { $0.name == "set-cookie" }.flatMap {
            HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": $0.value], for: url)
        }
        HTTPCookieStorage.shared.setCookies(cookies, for: url, mainDocumentURL: url)
    }

    /// The upgrade headers as URLSession sent them. A repeated name is joined with commas, as `URLRequest.addValue`
    /// did. Unless the caller supplies `Cookie`, stored cookies go along, matched on the URL's `https` form so that
    /// secure ones count. `Host` carries the port and IPv6 brackets; it comes last, after the join, so it replaces any
    /// that the caller passed.
    static func upgradeHeaders(url: URL, headers: [(name: String, value: String)]) -> [(name: String, value: String)] {
        let callerCookie = headers.contains { $0.name.caseInsensitiveCompare("Cookie") == .orderedSame }
        let cookies = callerCookie ? [] : cookieURL(url).flatMap { HTTPCookieStorage.shared.cookies(for: $0) } ?? []
        let stored = HTTPCookie.requestHeaderFields(with: cookies).map { (name: $0.key, value: $0.value) }

        var joined: [(name: String, value: String)] = []
        for (name, value) in headers + stored where name.caseInsensitiveCompare("Host") != .orderedSame {
            if let index = joined.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                joined[index].value += (name.caseInsensitiveCompare("Cookie") == .orderedSame ? "; " : ",") + value
            } else {
                joined.append((name, value))
            }
        }
        for (name, value) in [("Accept", "*/*"), ("Accept-Encoding", "gzip, deflate"), ("Sec-WebSocket-Extensions", "permessage-deflate")]
            where !joined.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        {
            joined.append((name, value))
        }
        guard let host = url.host else { return joined }
        let port = url.port.map { ":\($0)" } ?? ""
        let address = host.contains(":") ? String(host.prefix { $0 != "%" }) : host
        return joined + [(name: "Host", value: (host.contains(":") ? "[\(address)]" : address) + port)]
    }
}
