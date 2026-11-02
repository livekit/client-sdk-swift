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

internal import CFNetwork
import Foundation

extension WebSocket {
    /// URLSession follows at most twenty HTTP redirects, drops caller Authorization even on the same host, and permits
    /// transitions between secure and cleartext WebSocket/HTTP URLs. The caller rebuilds Host and stored cookies.
    static func redirectedURL(_ response: WebSocketUpgradeFailure, from url: URL) throws -> URL? {
        guard [301, 302, 303, 307, 308].contains(response.statusCode) else { return nil }
        let locations = response.headers.filter { $0.name == "location" }.map(\.value)
        guard locations.count == 1, let location = locations.first, !location.isEmpty,
              let target = URL(string: location, relativeTo: url)?.absoluteURL,
              var components = URLComponents(url: target, resolvingAgainstBaseURL: true) else { return nil }
        switch components.scheme?.lowercased() {
        case "ws", "http": components.scheme = "ws"
        case "wss", "https": components.scheme = "wss"
        default: throw LiveKitError(.network, internalError: URLError(.unsupportedURL))
        }
        guard let host = components.host, !host.isEmpty else { throw LiveKitError(.network, internalError: URLError(.badURL)) }
        return components.url
    }

    static func isSameOrigin(_ source: URL, _ target: URL) -> Bool {
        guard let source = httpURL(source), let target = httpURL(target), source.scheme == target.scheme,
              let sourceHost = source.host, let targetHost = target.host,
              sourceHost.caseInsensitiveCompare(targetHost) == .orderedSame else { return false }
        let defaultPort = source.scheme == "https" ? 443 : 80
        return (source.port ?? defaultPort) == (target.port ?? defaultPort)
    }

    /// The default credential is scoped to this endpoint and Basic realm. CFNetwork builds the header, as it did for
    /// URLSession; every CFHTTPMessage here is local to this call. The caller permits only one challenge retry.
    static func basicAuthorization(_ response: WebSocketUpgradeFailure, url: URL) -> String? {
        guard response.statusCode == 401, let url = httpURL(url), let host = url.host else { return nil }
        let challenges = response.headers.filter { $0.name == "www-authenticate" }.map(\.value)
        guard challengeSchemes(challenges).isDisjoint(with: ["digest", "ntlm", "negotiate"]) else { return nil }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        for header in challenges {
            for realm in basicRealms(header) {
                let space = URLProtectionSpace(host: host, port: port, protocol: url.scheme, realm: realm,
                                               authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
                guard let credential = URLCredentialStorage.shared.defaultCredential(for: space),
                      let user = credential.user, let password = credential.password else { continue }
                let request = CFHTTPMessageCreateRequest(nil, "GET" as CFString, url as CFURL, kCFHTTPVersion1_1).takeRetainedValue()
                let challenge = CFHTTPMessageCreateResponse(nil, 401, nil, kCFHTTPVersion1_1).takeRetainedValue()
                CFHTTPMessageSetHeaderFieldValue(challenge, "WWW-Authenticate" as CFString, header as CFString)
                guard CFHTTPMessageAddAuthentication(request, challenge, user as CFString, password as CFString,
                                                     kCFHTTPAuthenticationSchemeBasic, false),
                    let value = CFHTTPMessageCopyHeaderFieldValue(request, "Authorization" as CFString)?.takeRetainedValue() else { continue }
                return value as String
            }
        }
        return nil
    }

    private static func challengeSchemes(_ headers: [String]) -> Set<String> {
        Set(headers.flatMap(authenticationFields).compactMap { field in
            let prefix = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let tokens = prefix.split(whereSeparator: \.isWhitespace)
            guard !field.contains("=") || tokens.count > 1 else { return nil }
            return tokens.first.map { String($0).lowercased() }
        })
    }

    /// Commas inside quoted realms are data; commas between parameters/challenges separate fields (RFC 7235).
    private static func authenticationFields(_ header: String) -> [String] {
        var fields: [String] = [], field = ""
        var quoted = false, escaped = false
        for character in header {
            if escaped {
                escaped = false
            } else if quoted, character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                fields.append(field)
                field = ""
                continue
            }
            field.append(character)
        }
        guard !quoted, !escaped else { return [] }
        return fields + [field]
    }

    private static func basicRealms(_ header: String) -> [String] {
        var basic = false
        return authenticationFields(header).compactMap { field in
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let prefix = pair.first, let value = pair.last else {
                basic = false
                return nil
            }
            let names = prefix.split(whereSeparator: \.isWhitespace).map(String.init)
            guard (1 ... 2).contains(names.count) else {
                basic = false
                return nil
            }
            if names.count == 2 { basic = names.first?.caseInsensitiveCompare("Basic") == .orderedSame }
            guard basic, names.last?.caseInsensitiveCompare("realm") == .orderedSame else { return nil }
            return authenticationValue(value.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func authenticationValue(_ raw: String) -> String? {
        guard !raw.contains(where: \.isNewline) else { return nil }
        guard raw.first == "\"" else {
            let invalid = CharacterSet(charactersIn: "()<>@,;:\\\"/[]?={} \t\r\n")
            return !raw.isEmpty && raw.unicodeScalars.allSatisfy { $0.value < 127 && $0.value > 32 && !invalid.contains($0) } ? raw : nil
        }
        guard raw.count >= 2, raw.last == "\"" else { return nil }
        var value = "", escaped = false
        for character in raw.dropFirst().dropLast() {
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" || character.isNewline {
                return nil
            } else {
                value.append(character)
            }
        }
        return escaped ? nil : value
    }
}
