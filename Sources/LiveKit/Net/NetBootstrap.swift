// Copyright 2026 LiveKit (Apache-2.0)
internal import LiveKitUniFFI

/// One-time registration of the SDK's transports with `livekit-net`.
/// `setHttpClient`/`setWsClient` are first-registration-wins; a Swift `static let`
/// guarantees this runs exactly once, thread-safe, before the first connection.
enum LKNet {
    #if DEBUG
    // Swappable forwarding wrappers so FFI-demo tests can inject dummies.
    static let httpClient = LKNetHTTPClient()
    static let wsClient = LKNetWSClient()
    #endif

    static let bootstrap: Void = {
        #if DEBUG
        setHttpClient(c: httpClient)
        setWsClient(c: wsClient)
        #else
        setHttpClient(c: LKNetHTTPClientLive())
        setWsClient(c: LKNetWSClientLive())
        #endif
    }()
}
