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

@testable import LiveKit
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

class URLTests: LKTestCase {
    // MARK: - isValidForConnect

    func testIsValidForConnectWithWS() {
        let url = URL(string: "ws://localhost:7880")!
        XCTAssertTrue(url.isValidForConnect)
    }

    func testIsValidForConnectWithWSS() {
        let url = URL(string: "wss://example.livekit.cloud")!
        XCTAssertTrue(url.isValidForConnect)
    }

    func testIsValidForConnectWithHTTP() {
        let url = URL(string: "http://localhost:7880")!
        XCTAssertTrue(url.isValidForConnect)
    }

    func testIsValidForConnectWithHTTPS() {
        let url = URL(string: "https://example.livekit.cloud")!
        XCTAssertTrue(url.isValidForConnect)
    }

    func testIsNotValidForConnectWithFTP() {
        let url = URL(string: "ftp://example.com")!
        XCTAssertFalse(url.isValidForConnect)
    }

    func testIsNotValidForConnectWithoutHost() {
        let url = URL(string: "ws://")!
        XCTAssertFalse(url.isValidForConnect)
    }

    // MARK: - isValidForSocket

    func testIsValidForSocketWithWS() {
        let url = URL(string: "ws://localhost:7880")!
        XCTAssertTrue(url.isValidForSocket)
    }

    func testIsValidForSocketWithWSS() {
        let url = URL(string: "wss://example.com")!
        XCTAssertTrue(url.isValidForSocket)
    }

    func testIsNotValidForSocketWithHTTP() {
        let url = URL(string: "http://localhost:7880")!
        XCTAssertFalse(url.isValidForSocket)
    }

    // MARK: - isSecure

    func testIsSecureWSS() {
        XCTAssertTrue(URL(string: "wss://example.com")!.isSecure)
    }

    func testIsSecureHTTPS() {
        XCTAssertTrue(URL(string: "https://example.com")!.isSecure)
    }

    func testIsNotSecureWS() {
        XCTAssertFalse(URL(string: "ws://localhost")!.isSecure)
    }

    func testIsNotSecureHTTP() {
        XCTAssertFalse(URL(string: "http://localhost")!.isSecure)
    }

    // MARK: - isCloud

    func testIsCloudLiveKitCloud() {
        let url = URL(string: "wss://myapp.livekit.cloud")!
        XCTAssertTrue(url.isCloud)
    }

    func testIsCloudLiveKitRun() {
        let url = URL(string: "wss://myapp.livekit.run")!
        XCTAssertTrue(url.isCloud)
    }

    func testIsNotCloudLocalhost() {
        let url = URL(string: "ws://localhost:7880")!
        XCTAssertFalse(url.isCloud)
    }

    func testIsNotCloudCustomDomain() {
        let url = URL(string: "wss://livekit.example.com")!
        XCTAssertFalse(url.isCloud)
    }

    // MARK: - Protocol Conversion

    func testToSocketUrlFromHTTP() {
        let url = URL(string: "http://localhost:7880")!
        XCTAssertEqual(url.toSocketUrl().scheme, "ws")
    }

    func testToSocketUrlFromHTTPS() {
        let url = URL(string: "https://example.livekit.cloud")!
        XCTAssertEqual(url.toSocketUrl().scheme, "wss")
    }

    func testToSocketUrlPreservesPath() {
        let url = URL(string: "https://example.com/custom/path")!
        let socketUrl = url.toSocketUrl()
        XCTAssertEqual(socketUrl.path, "/custom/path")
    }

    func testToHTTPUrlFromWS() {
        let url = URL(string: "ws://localhost:7880")!
        XCTAssertEqual(url.toHTTPUrl().scheme, "http")
    }

    func testToHTTPUrlFromWSS() {
        let url = URL(string: "wss://example.livekit.cloud")!
        XCTAssertEqual(url.toHTTPUrl().scheme, "https")
    }

    func testToHTTPUrlPreservesHost() {
        let url = URL(string: "wss://example.livekit.cloud:443/path")!
        let httpUrl = url.toHTTPUrl()
        XCTAssertEqual(httpUrl.host, "example.livekit.cloud")
        XCTAssertEqual(httpUrl.path, "/path")
    }

    // MARK: - Cloud Config URL

    func testCloudConfigUrl() {
        let url = URL(string: "wss://myapp.livekit.cloud")!
        let configUrl = url.cloudConfigUrl()
        XCTAssertEqual(configUrl.scheme, "https")
        XCTAssertEqual(configUrl.path, "/settings")
        XCTAssertEqual(configUrl.host, "myapp.livekit.cloud")
    }

    func testCloudConfigUrlStripsQueryAndFragment() {
        let url = URL(string: "wss://myapp.livekit.cloud?token=abc#section")!
        let configUrl = url.cloudConfigUrl()
        XCTAssertNil(configUrl.query)
        XCTAssertNil(configUrl.fragment)
    }

    func testRegionSettingsUrl() {
        let url = URL(string: "wss://myapp.livekit.cloud")!
        let regionUrl = url.regionSettingsUrl()
        XCTAssertTrue(regionUrl.path.contains("/settings/regions"))
    }

    // MARK: - Region Manager Key URL

    func testRegionManagerKeyUrlStripsRtcSuffix() {
        let url = URL(string: "wss://example.com/rtc")!
        let keyUrl = url.regionManagerKeyURL()
        XCTAssertFalse(keyUrl.path.contains("rtc"))
    }

    func testRegionManagerKeyUrlStripsValidateSuffix() {
        let url = URL(string: "wss://example.com/validate")!
        let keyUrl = url.regionManagerKeyURL()
        XCTAssertFalse(keyUrl.path.contains("validate"))
    }

    func testRegionManagerKeyUrlPreservesSubPaths() {
        let url = URL(string: "wss://example.com/custom/rtc")!
        let keyUrl = url.regionManagerKeyURL()
        XCTAssertTrue(keyUrl.path.contains("custom"))
        XCTAssertFalse(keyUrl.path.contains("rtc"))
    }

    func testMatchesRegionManagerKey() {
        let a = URL(string: "wss://example.com/rtc")!
        let b = URL(string: "wss://example.com/validate")!
        XCTAssertTrue(a.matchesRegionManagerKey(of: b))
    }

    func testDoesNotMatchDifferentRegionManagerKey() {
        let a = URL(string: "wss://example.com/path1/rtc")!
        let b = URL(string: "wss://other.com/rtc")!
        XCTAssertFalse(a.matchesRegionManagerKey(of: b))
    }
}
