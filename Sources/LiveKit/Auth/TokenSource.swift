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

// MARK: - Token

/// `Token` represent the credentials needed for connecting to a new Room.
/// - SeeAlso: [LiveKit's Authentication Documentation](https://docs.livekit.io/home/get-started/authentication/) for more information.
public enum Token {
    /// Request parameters for generating connection credentials.
    public struct Request: Encodable, Sendable, Equatable {
        /// The name of the room being requested when generating credentials.
        public let roomName: String?
        /// The name of the participant being requested for this client when generating credentials.
        public let participantName: String?
        /// The identity of the participant being requested for this client when generating credentials.
        public let participantIdentity: String?
        /// Any participant metadata being included along with the credentials generation operation.
        public let participantMetadata: String?
        /// Any participant attributes being included along with the credentials generation operation.
        public let participantAttributes: [String: String]?
        /// A `RoomConfiguration` object can be passed to request extra parameters when generating connection credentials.
        /// Used for advanced room configuration like dispatching agents, setting room limits, etc.
        /// - SeeAlso: [Room Configuration Documentation](https://docs.livekit.io/home/get-started/authentication/#room-configuration) for more info.
        public let roomConfiguration: RoomConfiguration?

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
        public let serverURL: URL
        /// The JWT token containing participant permissions and metadata.
        public let participantToken: String

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

// MARK: - Source

/// Protocol for types that can provide connection credentials.
/// Implement this protocol to create custom credential providers (e.g., fetching from your backend API).
public protocol TokenSource: Sendable {
    /// Fetch connection credentials for the given request.
    /// - Parameter request: The token request containing room and participant information
    /// - Returns: A token response containing the server URL and participant token
    /// - Throws: An error if the token generation fails
    func fetch(_ request: Token.Request) async throws -> Token.Response
}

/// `Token.Literal` contains a single set of credentials, hard-coded or acquired from a static source.
extension Token.Literal: TokenSource {
    public func fetch(_: Token.Request) async throws -> Token.Response {
        self
    }
}

// MARK: - Endpoint

/// Protocol for token servers that fetch credentials via HTTP requests.
/// Provides a default implementation of `fetch` that can be used to integrate with custom backend token generation endpoints.
/// - Note: The response is expected to be a `Token.Response` object.
public protocol TokenEndpoint: TokenSource {
    /// The URL endpoint for token generation.
    var url: URL { get }
    /// The HTTP method to use (defaults to "POST").
    var method: String { get }
    /// Additional HTTP headers to include with the request.
    var headers: [String: String] { get }
}

public extension TokenEndpoint {
    var method: String { "POST" }
    var headers: [String: String] { [:] }

    func fetch(_ request: Token.Request) async throws -> Token.Response {
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

        return try JSONDecoder().decode(Token.Response.self, from: data)
    }
}

// MARK: - Cache

/// `CachingTokenSource` handles caching of credentials from any other `TokenSource` using configurable store.
public actor CachingTokenSource: TokenSource, Loggable {
    /// A tuple containing the request and response that were cached.
    public typealias Cached = (Token.Request, Token.Response)
    /// A closure that validates whether cached credentials are still valid.
    /// - Parameters:
    ///   - request: The original token request
    ///   - response: The cached token response
    /// - Returns: `true` if the cached credentials are still valid, `false` otherwise
    public typealias TokenValidator = (Token.Request, Token.Response) -> Bool

    private let source: TokenSource
    private let store: TokenStore
    private let validator: TokenValidator

    /// Initialize a caching wrapper around any credentials provider.
    /// - Parameters:
    ///   - source: The underlying token source to wrap
    ///   - store: The store implementation to use for caching (defaults to in-memory store)
    ///   - validator: A closure to determine if cached credentials are still valid (defaults to JWT expiration check)
    public init(
        _ source: TokenSource,
        store: TokenStore = InMemoryTokenStore(),
        validator: @escaping TokenValidator = { _, response in response.hasValidToken() }
    ) {
        self.source = source
        self.store = store
        self.validator = validator
    }

    public func fetch(_ request: Token.Request) async throws -> Token.Response {
        if let (cachedRequest, cachedResponse) = await store.retrieve(),
           cachedRequest == request,
           validator(cachedRequest, cachedResponse)
        {
            log("Using cached credentials", .debug)
            return cachedResponse
        }

        log("Requesting new credentials", .debug)
        let response = try await source.fetch(request)
        await store.store((request, response))
        return response
    }

    /// Invalidate the cached credentials, forcing a fresh fetch on the next request.
    public func invalidate() async {
        await store.clear()
    }

    /// Get the cached credentials
    /// - Returns: The cached token if found, nil otherwise
    public func cachedToken() async -> Token.Response? {
        await store.retrieve()?.1
    }
}

// MARK: - Store

/// Protocol for abstract store that can persist and retrieve a single cached credential pair.
/// Implement this protocol to create custom store implementations e.g. for Keychain.
public protocol TokenStore: Sendable {
    /// Store credentials in the store (replaces any existing credentials)
    func store(_ credentials: CachingTokenSource.Cached) async

    /// Retrieve the cached credentials
    /// - Returns: The cached credentials if found, nil otherwise
    func retrieve() async -> CachingTokenSource.Cached?

    /// Clear the stored credentials
    func clear() async
}

/// Simple in-memory store implementation
public actor InMemoryTokenStore: TokenStore {
    private var cached: CachingTokenSource.Cached?

    public init() {}

    public func store(_ credentials: CachingTokenSource.Cached) async {
        cached = credentials
    }

    public func retrieve() async -> CachingTokenSource.Cached? {
        cached
    }

    public func clear() async {
        cached = nil
    }
}

// MARK: - Validation

public extension Token.Response {
    /// Validates whether the JWT token is still valid.
    /// - Parameter tolerance: Time tolerance in seconds for token expiration check (default: 60 seconds)
    /// - Returns: `true` if the token is valid and not expired, `false` otherwise
    func hasValidToken(withTolerance tolerance: TimeInterval = 60) -> Bool {
        guard let jwt = jwt() else {
            return false
        }

        do {
            try jwt.nbf.verifyNotBefore()
            try jwt.exp.verifyNotExpired(currentDate: Date().addingTimeInterval(tolerance))
        } catch {
            return false
        }

        return true
    }

    /// Extracts the JWT payload from the participant token.
    /// - Returns: The JWT payload if found, nil otherwise
    func jwt() -> LiveKitJWTPayload? {
        LiveKitJWTPayload.fromUnverified(token: participantToken)
    }
}
