// Copyright 2026 LiveKit (Apache-2.0)
import Foundation
import Testing
@testable import LiveKit

struct LKNetWSConnectionTests {
    @Test func decodeDataFrame() {
        let d = Data([0x01, 0x02, 0x03])
        #expect(LKNetWSConnection.decode(.data(d)) == d)
    }

    @Test func decodeStringFrameIsUTF8() {
        #expect(LKNetWSConnection.decode(.string("hi")) == Data("hi".utf8))
    }
}
