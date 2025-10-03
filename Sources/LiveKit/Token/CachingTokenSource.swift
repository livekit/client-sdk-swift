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

/// `CachingTokenSource` handles caching of credentials from any other `TokenSource` using configurable store.
public actor CachingTokenSource: TokenSourceConfigurable, Loggable {
    /// A tuple containing the request and response that were cached.
    public typealias Cached = (TokenRequestOptions, TokenSourceResponse)
    /// A closure that validates whether cached credentials are still valid.
    /// - Parameters:
    ///   - request: The original token request
    ///   - response: The cached token response
    /// - Returns: `true` if the cached credentials are still valid, `false` otherwise
    public typealias TokenValidator = @Sendable (TokenRequestOptions, TokenSourceResponse) -> Bool

    private let source: TokenSourceConfigurable
    private let store: TokenStore
    private let validator: TokenValidator

    /// Initialize a caching wrapper around any credentials provider.
    /// - Parameters:
    ///   - source: The underlying token source to wrap
    ///   - store: The store implementation to use for caching (defaults to in-memory store)
    ///   - validator: A closure to determine if cached credentials are still valid (defaults to JWT expiration check)
    public init(
        _ source: TokenSourceConfigurable,
        store: TokenStore = InMemoryTokenStore(),
        validator: @escaping TokenValidator = { _, response in response.hasValidToken() }
    ) {
        self.source = source
        self.store = store
        self.validator = validator
    }

    public func fetch(_ options: TokenRequestOptions) async throws -> TokenSourceResponse {
        if let (cachedOptions, cachedResponse) = await store.retrieve(),
           cachedOptions == options,
           validator(cachedOptions, cachedResponse)
        {
            log("Using cached credentials", .debug)
            return cachedResponse
        }

        log("Requesting new credentials", .debug)
        let response = try await source.fetch(options)
        await store.store((options, response))
        return response
    }

    /// Invalidate the cached credentials, forcing a fresh fetch on the next request.
    public func invalidate() async {
        await store.clear()
    }

    /// Get the cached credentials
    /// - Returns: The cached token if found, nil otherwise
    public func cachedToken() async -> TokenSourceResponse? {
        await store.retrieve()?.1
    }
}

public extension TokenSourceConfigurable {
    func cached(store: TokenStore = InMemoryTokenStore(), validator: @escaping CachingTokenSource.TokenValidator = { _, response in response.hasValidToken() }) -> CachingTokenSource {
        CachingTokenSource(self, store: store, validator: validator)
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

public extension TokenSourceResponse {
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
