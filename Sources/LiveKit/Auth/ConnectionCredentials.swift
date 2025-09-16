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

public enum ConnectionCredentials {
    public struct Request: Encodable, Equatable, Sendable {
        let roomName: String? = nil
        let participantName: String? = nil
        let participantIdentity: String? = nil
        let participantMetadata: String? = nil
        let participantAttributes: [String: String]? = nil
//        let roomConfiguration: RoomConfiguration? = nil
    }

    public struct Response: Decodable, Sendable {
        let serverUrl: URL
        let participantToken: String
    }

    public typealias Literal = Response
}

// MARK: - Provider

public protocol CredentialsProvider: Sendable {
    func fetch(_ request: ConnectionCredentials.Request) async throws -> ConnectionCredentials.Response
}

// MARK: - Implementation

extension ConnectionCredentials.Literal: CredentialsProvider {
    public func fetch(_: ConnectionCredentials.Request) async throws -> ConnectionCredentials.Response {
        self
    }
}

public struct SandboxTokenServer: CredentialsProvider, Loggable {
    private static let baseURL = URL(string: "https://cloud-api.livekit.io")!

    public struct Options: Sendable {
        let id: String
        let baseURL: URL? = nil
    }

    private let options: Options

    public init(options: Options) {
        self.options = options
    }

    public init(id: String) {
        options = .init(id: id)
    }

    public func fetch(_ request: ConnectionCredentials.Request) async throws -> ConnectionCredentials.Response {
        log("Using sandbox token server is not applicable for production environemnt", .info)

        let baseURL = options.baseURL ?? Self.baseURL
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/sandbox/connection-details"))

        urlRequest.httpMethod = "POST"
        urlRequest.addValue(options.id.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), forHTTPHeaderField: "X-Sandbox-ID")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveKitError(.network, message: "Error generating token from sandbox token server, no response")
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw LiveKitError(.network, message: "Error generating token from sandbox token server, received \(httpResponse)")
        }

        return try JSONDecoder().decode(ConnectionCredentials.Response.self, from: data)
    }
}

// MARK: - Cache

public actor CachingCredentialsProvider: CredentialsProvider, Loggable {
    private let provider: CredentialsProvider
    private let validator: (ConnectionCredentials.Request, ConnectionCredentials.Response) -> Bool

    private var cached: (ConnectionCredentials.Request, ConnectionCredentials.Response)?

    public init(_ provider: CredentialsProvider, validator: @escaping (ConnectionCredentials.Request, ConnectionCredentials.Response) -> Bool = { _, res in res.hasValidToken() }) {
        self.provider = provider
        self.validator = validator
    }

    public func fetch(_ request: ConnectionCredentials.Request) async throws -> ConnectionCredentials.Response {
        if let (cachedRequest, cachedResponse) = cached, cachedRequest == request, validator(cachedRequest, cachedResponse) {
            log("Using cached credentials", .debug)
            return cachedResponse
        }

        let response = try await provider.fetch(request)
        cached = (request, response)
        return response
    }

    public func invalidate() {
        cached = nil
    }
}

// MARK: - Validation

public extension ConnectionCredentials.Response {
    func hasValidToken(withTolerance tolerance: TimeInterval = 60) -> Bool {
        let parts = participantToken.components(separatedBy: ".")
        guard parts.count == 3 else {
            return false
        }

        let payloadData = parts[1]

        struct JWTPayload: Decodable {
            let exp: Double
        }

        guard let payloadJSON = payloadData.base64URLDecode(),
              let payload = try? JSONDecoder().decode(JWTPayload.self, from: payloadJSON)
        else {
            return false
        }

        let now = Date().timeIntervalSince1970
        return payload.exp > now - tolerance
    }
}

private extension String {
    func base64URLDecode() -> Data? {
        var base64 = self
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")

        while base64.count % 4 != 0 {
            base64.append("=")
        }

        return Data(base64Encoded: base64)
    }
}
