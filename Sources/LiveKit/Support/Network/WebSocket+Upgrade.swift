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

    /// Reads the answer to the upgrade request up to its blank line, and resumes `opening` with the bytes after it, which
    /// can hold the first frames, once the server switches protocols with the accept key that `key` asks for.
    static func readUpgradeResponse(_ connection: NWConnection, key: String, into opening: AsyncCompleter<Data>, read: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: upgradeResponseLimit - read.count) { content, _, isComplete, error in
            let read = read + (content ?? Data())
            guard let end = read.range(of: Data("\r\n\r\n".utf8)) else {
                if let error { return opening.resume(throwing: error) }
                guard !isComplete, read.count < upgradeResponseLimit else { return opening.resume(throwing: badUpgradeResponse) }
                return readUpgradeResponse(connection, key: key, into: opening, read: read)
            }
            if let failure = upgradeFailure(head: read[..<end.lowerBound], key: key) {
                return opening.resume(throwing: failure)
            }
            opening.resume(returning: Data(read[end.upperBound...]))
        }
    }

    /// Why the response head `head` does not open the socket: an HTTP status other than 101, which the caller gets as a
    /// ``WebSocketUpgradeFailure``, or a malformed head or a wrong accept key. Nil when it opens.
    static func upgradeFailure(head: Data, key: String) -> LiveKitError? {
        guard let lines = String(bytes: head, encoding: .isoLatin1)?.components(separatedBy: "\r\n"),
              // "HTTP/1.1 101 Switching Protocols"
              let status = lines.first.flatMap({ $0.split(separator: " ").dropFirst().first }).flatMap({ Int($0) })
        else { return badUpgradeResponse }
        guard status == 101 else {
            return LiveKitError(.network, internalError: WebSocketUpgradeFailure(statusCode: status))
        }
        let field = "sec-websocket-accept:"
        let accept = lines.dropFirst()
            .first { $0.lowercased().hasPrefix(field) }
            .map { $0.dropFirst(field.count).trimmingCharacters(in: .whitespaces) }
        let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        return accept == expected ? nil : badUpgradeResponse
    }

    private static var badUpgradeResponse: LiveKitError {
        LiveKitError(.network, internalError: URLError(.badServerResponse))
    }

    /// The upgrade headers as URLSession sent them. A repeated name is joined with commas, as `URLRequest.addValue`
    /// did. Unless the caller supplies `Cookie`, stored cookies go along, matched on the URL's `https` form so that
    /// secure ones count. `Host` carries the port and IPv6 brackets; it comes last, after the join, so it replaces any
    /// that the caller passed.
    static func upgradeHeaders(url: URL, headers: [(name: String, value: String)]) -> [(name: String, value: String)] {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = url.scheme == "wss" ? "https" : "http"
        let callerCookie = headers.contains { $0.name.caseInsensitiveCompare("Cookie") == .orderedSame }
        let cookies = callerCookie ? [] : components?.url.flatMap { HTTPCookieStorage.shared.cookies(for: $0) } ?? []
        let stored = HTTPCookie.requestHeaderFields(with: cookies).map { (name: $0.key, value: $0.value) }

        var joined: [(name: String, value: String)] = []
        for (name, value) in headers + stored where name.caseInsensitiveCompare("Host") != .orderedSame {
            if let index = joined.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                joined[index].value += (name.caseInsensitiveCompare("Cookie") == .orderedSame ? "; " : ",") + value
            } else {
                joined.append((name, value))
            }
        }
        guard let host = url.host else { return joined }
        let port = url.port.map { ":\($0)" } ?? ""
        let address = host.contains(":") ? String(host.prefix { $0 != "%" }) : host
        return joined + [(name: "Host", value: (host.contains(":") ? "[\(address)]" : address) + port)]
    }
}
