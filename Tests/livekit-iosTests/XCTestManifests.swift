import XCTest

#if !canImport(ObjectiveC)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(livekit_iosTests.allTests),
    ]
}
#endif
