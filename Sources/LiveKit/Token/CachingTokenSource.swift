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

/// A token source that caches credentials from any other ``TokenSourceConfigurable`` using a configurable store.
///
/// This wrapper improves performance by avoiding redundant token requests when credentials are still valid.
/// It automatically validates cached tokens and fetches new ones when needed.
public actor CachingTokenSource: TokenSourceConfigurable, Loggable {
    /// A tuple containing the request and response that were cached.
    public typealias Cached = (TokenRequestOptions, TokenSourceResponse)

    /// A closure that validates whether cached credentials are still valid.
    ///
    /// The validator receives the original request options and cached response, and should return
    /// `true` if the cached credentials are still valid for the given request.
    public typealias Validator = @Sendable (TokenRequestOptions, TokenSourceResponse) -> Bool

    /// Protocol for storing and retrieving cached token credentials.
    ///
    /// Implement this protocol to create custom storage solutions like Keychain,
    /// or database-backed storage for token caching.
    public protocol Store: Sendable {
        /// Store credentials in the store.
        ///
        /// This replaces any existing cached credentials with the new ones.
        func store(_ credentials: CachingTokenSource.Cached) async

        /// Retrieve the cached credentials.
        /// - Returns: The cached credentials if found, nil otherwise
        func retrieve() async -> CachingTokenSource.Cached?

        /// Clear all stored credentials.
        func clear() async
    }

    private let source: TokenSourceConfigurable
    private let store: Store
    private let validator: Validator

    /// Initialize a caching wrapper around any token source.
    ///
    /// - Parameters:
    ///   - source: The underlying token source to wrap and cache
    ///   - store: The store implementation to use for caching (defaults to in-memory store)
    ///   - validator: A closure to determine if cached credentials are still valid (defaults to JWT expiration check)
    public init(
        _ source: TokenSourceConfigurable,
        store: Store = InMemoryTokenStore(),
        validator: @escaping Validator = { _, response in response.hasValidToken() }
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
        let newResponse = try await source.fetch(options)
        await store.store((options, newResponse))

        return newResponse
    }

    /// Invalidate the cached credentials, forcing a fresh fetch on the next request.
    public func invalidate() async {
        await store.clear()
    }

    /// Get the cached credentials
    /// - Returns: The cached response if found, nil otherwise.
    public func cachedResponse() async -> TokenSourceResponse? {
        await store.retrieve()?.1
    }
}

public extension TokenSourceConfigurable {
    /// Wraps this token source with caching capabilities.
    ///
    /// The returned token source will reuse valid tokens and only fetch new ones when needed.
    ///
    /// - Parameters:
    ///   - store: The store implementation to use for caching (defaults to in-memory store)
    ///   - validator: A closure to determine if cached credentials are still valid (defaults to JWT expiration check)
    /// - Returns: A caching token source that wraps this token source
    func cached(store: CachingTokenSource.Store = InMemoryTokenStore(),
                validator: @escaping CachingTokenSource.Validator = { _, response in response.hasValidToken() }) -> CachingTokenSource
    {
        CachingTokenSource(self, store: store, validator: validator)
    }
}

// MARK: - Store

/// A simple in-memory store implementation for token caching.
///
/// This store keeps credentials in memory and is lost when the app is terminated.
/// Suitable for development and testing, but consider persistent storage for production.
public actor InMemoryTokenStore: CachingTokenSource.Store {
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
    /// Validates whether the JWT token is still valid and not expired.
    ///
    /// - Parameter tolerance: Time tolerance in seconds for token expiration check (default: 60 seconds)
    /// - Returns: `true` if the token is valid and not expired, `false` otherwise
    func hasValidToken(withTolerance tolerance: TimeInterval = 60) -> Bool {
        guard let jwt = jwt() else {
            return false
        }

        return jwt.nbf.verifyNotBefore() && jwt.exp.verifyNotExpired(currentDate: Date().addingTimeInterval(tolerance))
    }
}

private extension UInt64 {
    var asDate: Date {
        Date(timeIntervalSince1970: TimeInterval(self))
    }

    func verifyNotBefore(currentDate: Date = Date()) -> Bool {
        currentDate >= asDate
    }

    func verifyNotExpired(currentDate: Date = Date()) -> Bool {
        currentDate < asDate
    }
}
