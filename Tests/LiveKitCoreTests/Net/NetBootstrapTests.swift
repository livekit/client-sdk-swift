// Copyright 2026 LiveKit (Apache-2.0)
import Testing
@testable import LiveKit
import LiveKitUniFFI

struct NetBootstrapTests {
    @Test func bootstrapRegistersTransports() {
        _ = LKNet.bootstrap
        #expect(hasHttpClient())
        #expect(hasWsClient())
    }
}
