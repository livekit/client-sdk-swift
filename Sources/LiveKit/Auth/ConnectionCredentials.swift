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

#warning("Fix camel case after deploying backend")

/// `ConnectionCredentials` represent the credentials needed for connecting to a new Room.
/// - SeeAlso: [LiveKit's Authentication Documentation](https://docs.livekit.io/home/get-started/authentication/) for more information.
public enum ConnectionCredentials {
    /// Request parameters for generating connection credentials.
    public struct Request: Encodable, Sendable, Equatable {
        /// The name of the room being requested when generating credentials.
        let roomName: String?
        /// The name of the participant being requested for this client when generating credentials.
        let participantName: String?
        /// The identity of the participant being requested for this client when generating credentials.
        let participantIdentity: String?
        /// Any participant metadata being included along with the credentials generation operation.
        let participantMetadata: String?
        /// Any participant attributes being included along with the credentials generation operation.
        let participantAttributes: [String: String]?
        /// A `RoomConfiguration` object can be passed to request extra parameters should be included when generating connection credentials - dispatching agents, etc.
        /// - SeeAlso: [Room Configuration Documentation](https://docs.livekit.io/home/get-started/authentication/#room-configuration) for more info.
        let roomConfiguration: RoomConfiguration?

        // enum CodingKeys: String, CodingKey {
        //     case roomName = "room_name"
        //     case participantName = "participant_name"
        //     case participantIdentity = "participant_identity"
        //     case participantMetadata = "participant_metadata"
        //     case participantAttributes = "participant_attributes"
        //     case roomConfiguration = "room_configuration"
        // }

        public init(
            roomName: String? = nil,
            participantName: String? = nil,
            participantIdentity: String? = nil,
            participantMetadata: String? = nil,
            participantAttributes: [String: String]? = nil,
            roomConfiguration: RoomConfiguration? = nil
        ) {
            self.roomName = roomName
            self.participantName = participantName
            self.participantIdentity = participantIdentity
            self.participantMetadata = participantMetadata
            self.participantAttributes = participantAttributes
            self.roomConfiguration = roomConfiguration
        }
    }

    /// Response containing the credentials needed to connect to a room.
    public struct Response: Decodable, Sendable {
        /// The WebSocket URL for the LiveKit server.
        let serverURL: URL
        /// The JWT token containing participant permissions and metadata.
        let participantToken: String

        enum CodingKeys: String, CodingKey {
            case serverURL = "serverUrl"
            case participantToken
        }

        public init(serverURL: URL, participantToken: String) {
            self.serverURL = serverURL
            self.participantToken = participantToken
        }
    }

    public typealias Options = Request
    public typealias Literal = Response
}

// MARK: - Provider

/// Protocol for types that can provide connection credentials.
/// Implement this protocol to create custom credential providers (e.g., fetching from your backend API).
public protocol CredentialsProvider: Sendable {
    func fetch(_ request: ConnectionCredentials.Request) async throws -> ConnectionCredentials.Response
}

/// `ConnectionCredentials.Literal` contains a single set of credentials, hard-coded or acquired from a static source.
/// - Note: It does not support refresing credentials.
extension ConnectionCredentials.Literal: CredentialsProvider {
    public func fetch(_: ConnectionCredentials.Request) async throws -> ConnectionCredentials.Response {
        self
    }
}

// MARK: - Token Server

/// Protocol for token servers that fetch credentials via HTTP requests.
/// Provides a default implementation of `fetch` that can be used to integrate with custom backend token generation endpoints.
/// - Note: The response is expected to be a `ConnectionCredentials.Response` object.
public protocol TokenServer: CredentialsProvider {
    /// The URL endpoint for token generation.
    var url: URL { get }
    /// The HTTP method to use (defaults to "POST").
    var method: String { get }
    /// Additional HTTP headers to include with the request.
    var headers: [String: String] { get }
}

public extension TokenServer {
    var method: String { "POST" }
    var headers: [String: String] { [:] }

    func fetch(_ request: ConnectionCredentials.Request) async throws -> ConnectionCredentials.Response {
        var urlRequest = URLRequest(url: url)

        urlRequest.httpMethod = method
        for (key, value) in headers {
            urlRequest.addValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveKitError(.network, message: "Error generating token from the token server, no response")
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw LiveKitError(.network, message: "Error generating token from the token server, received \(httpResponse)")
        }

        return try JSONDecoder().decode(ConnectionCredentials.Response.self, from: data)
    }
}

/// `SandboxTokenServer` queries LiveKit Sandbox token server for credentials,
/// which supports quick prototyping/getting started types of use cases.
/// - Warning: This token provider is **INSECURE** and should **NOT** be used in production.
public struct SandboxTokenServer: TokenServer {
    public let url = URL(string: "https://cloud-api.livekit.io/api/sandbox/connection-details")!
    public var headers: [String: String] {
        ["X-Sandbox-ID": id]
    }

    /// The sandbox ID provided by LiveKit Cloud.
    public let id: String

    /// Initialize with a sandbox ID from LiveKit Cloud.
    public init(id: String) {
        self.id = id.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}

// MARK: - Cache

/// `CachingCredentialsProvider` handles caching of credentials from any other `CredentialsProvider` using configurable store.
public actor CachingCredentialsProvider: CredentialsProvider, Loggable {
    /// A tuple containing the request and response that were cached.
    public typealias Cached = (ConnectionCredentials.Request, ConnectionCredentials.Response)
    /// A closure that validates whether cached credentials are still valid.
    public typealias Validator = (ConnectionCredentials.Request, ConnectionCredentials.Response) -> Bool

    private let provider: CredentialsProvider
    private let store: CredentialsStore
    private let validator: Validator

    /// Initialize a caching wrapper around any credentials provider.
    /// - Parameters:
    ///   - provider: The underlying credentials provider to wrap
    ///   - store: The store implementation to use for caching (defaults to in-memory store)
    ///   - validator: A closure to determine if cached credentials are still valid (defaults to JWT expiration check)
    public init(
        _ provider: CredentialsProvider,
        store: CredentialsStore = InMemoryCredentialsStore(),
        validator: @escaping Validator = { _, res in res.hasValidToken() }
    ) {
        self.provider = provider
        self.store = store
        self.validator = validator
    }

    public func fetch(_ request: ConnectionCredentials.Request) async throws -> ConnectionCredentials.Response {
        if let (cachedRequest, cachedResponse) = await store.retrieve(),
           cachedRequest == request,
           validator(cachedRequest, cachedResponse)
        {
            log("Using cached credentials", .debug)
            return cachedResponse
        }

        log("Requesting new credentials", .debug)
        let response = try await provider.fetch(request)
        await store.store((request, response))
        return response
    }

    /// Invalidate the cached credentials, forcing a fresh fetch on the next request.
    public func invalidate() async {
        await store.clear()
    }

    /// Get the cached credentials
    /// - Returns: The cached credentials if found, nil otherwise
    public func getCachedCredentials() async -> CachingCredentialsProvider.Cached? {
        await store.retrieve()
    }
}

// MARK: - Store

/// Protocol for abstract store that can persist and retrieve a single cached credential pair.
/// Implement this protocol to create custom store implementations e.g. for Keychain.
public protocol CredentialsStore: Sendable {
    /// Store credentials in the store (replaces any existing credentials)
    func store(_ credentials: CachingCredentialsProvider.Cached) async

    /// Retrieve the cached credentials
    /// - Returns: The cached credentials if found, nil otherwise
    func retrieve() async -> CachingCredentialsProvider.Cached?

    /// Clear the stored credentials
    func clear() async
}

/// Simple in-memory store implementation
public actor InMemoryCredentialsStore: CredentialsStore {
    private var cached: CachingCredentialsProvider.Cached?

    public init() {}

    public func store(_ credentials: CachingCredentialsProvider.Cached) async {
        cached = credentials
    }

    public func retrieve() async -> CachingCredentialsProvider.Cached? {
        cached
    }

    public func clear() async {
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
            let nbf: Double
            let exp: Double
        }

        guard let payloadJSON = payloadData.base64Decode(),
              let payload = try? JSONDecoder().decode(JWTPayload.self, from: payloadJSON)
        else {
            return false
        }

        let now = Date().timeIntervalSince1970
        return payload.nbf <= now && payload.exp > now - tolerance
    }
}

private extension String {
    func base64Decode() -> Data? {
        var base64 = self
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")

        while base64.count % 4 != 0 {
            base64.append("=")
        }

        return Data(base64Encoded: base64)
    }
}
