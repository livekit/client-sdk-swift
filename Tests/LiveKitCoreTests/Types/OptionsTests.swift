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

class OptionsTests: LKTestCase {
    // MARK: - Default Values

    func testDefaultInitValues() {
        let options = ConnectOptions()
        XCTAssertTrue(options.autoSubscribe)
        XCTAssertEqual(options.reconnectAttempts, 10)
        XCTAssertEqual(options.reconnectAttemptDelay, TimeInterval.defaultReconnectDelay)
        XCTAssertEqual(options.reconnectMaxDelay, TimeInterval.defaultReconnectMaxDelay)
        XCTAssertEqual(options.socketConnectTimeoutInterval, TimeInterval.defaultSocketConnect)
        XCTAssertEqual(options.primaryTransportConnectTimeout, TimeInterval.defaultTransportState)
        XCTAssertEqual(options.publisherTransportConnectTimeout, TimeInterval.defaultTransportState)
        XCTAssertTrue(options.iceServers.isEmpty)
        XCTAssertEqual(options.iceTransportPolicy, .all)
        XCTAssertFalse(options.isDscpEnabled)
        XCTAssertFalse(options.enableMicrophone)
    }

    func testParameterlessInitMatchesParameterizedDefaults() {
        let parameterless = ConnectOptions()
        let parameterized = ConnectOptions(
            autoSubscribe: true,
            reconnectAttempts: 10,
            reconnectAttemptDelay: .defaultReconnectDelay,
            reconnectMaxDelay: .defaultReconnectMaxDelay,
            socketConnectTimeoutInterval: .defaultSocketConnect,
            primaryTransportConnectTimeout: .defaultTransportState,
            publisherTransportConnectTimeout: .defaultTransportState
        )
        XCTAssertEqual(parameterless, parameterized)
    }

    // MARK: - Reconnect Delay Clamping

    func testReconnectMaxDelayClampedToAtLeastAttemptDelay() {
        // When maxDelay < attemptDelay, it should be clamped to attemptDelay
        let options = ConnectOptions(
            reconnectAttemptDelay: 5.0,
            reconnectMaxDelay: 2.0
        )
        XCTAssertEqual(options.reconnectMaxDelay, 5.0,
                       "reconnectMaxDelay should be clamped to reconnectAttemptDelay when smaller")
    }

    func testReconnectMaxDelayNotClampedWhenLarger() {
        let options = ConnectOptions(
            reconnectAttemptDelay: 0.5,
            reconnectMaxDelay: 10.0
        )
        XCTAssertEqual(options.reconnectMaxDelay, 10.0)
    }

    func testReconnectMaxDelayEqualToAttemptDelay() {
        let options = ConnectOptions(
            reconnectAttemptDelay: 3.0,
            reconnectMaxDelay: 3.0
        )
        XCTAssertEqual(options.reconnectMaxDelay, 3.0)
    }

    // MARK: - Default Values Sanity

    func testDefaultValuesArePositive() {
        let options = ConnectOptions()
        XCTAssertGreaterThan(options.reconnectAttempts, 0)
        XCTAssertGreaterThan(options.reconnectAttemptDelay, 0)
        XCTAssertGreaterThan(options.reconnectMaxDelay, 0)
        XCTAssertGreaterThan(options.socketConnectTimeoutInterval, 0)
        XCTAssertGreaterThan(options.primaryTransportConnectTimeout, 0)
        XCTAssertGreaterThan(options.publisherTransportConnectTimeout, 0)
    }

    func testMaxDelayIsGreaterThanAttemptDelay() {
        let options = ConnectOptions()
        XCTAssertGreaterThanOrEqual(options.reconnectMaxDelay, options.reconnectAttemptDelay)
    }

    // MARK: - Equality

    func testEqualityWithSameValues() {
        let a = ConnectOptions(reconnectAttempts: 5, reconnectAttemptDelay: 1.0)
        let b = ConnectOptions(reconnectAttempts: 5, reconnectAttemptDelay: 1.0)
        XCTAssertEqual(a, b)
    }

    func testInequalityWithDifferentValues() {
        let a = ConnectOptions(reconnectAttempts: 5)
        let b = ConnectOptions(reconnectAttempts: 10)
        XCTAssertNotEqual(a, b)
    }

    func testEqualityWithNonConnectOptionsObject() {
        let options = ConnectOptions()
        XCTAssertFalse(options.isEqual("not ConnectOptions"))
        XCTAssertFalse(options.isEqual(nil))
    }

    // MARK: - Hashing

    func testHashConsistency() {
        let a = ConnectOptions(reconnectAttempts: 5, reconnectAttemptDelay: 1.0)
        let b = ConnectOptions(reconnectAttempts: 5, reconnectAttemptDelay: 1.0)
        XCTAssertEqual(a.hash, b.hash)
    }

    // MARK: - Custom Values

    func testCustomIceServers() {
        let server = IceServer(urls: ["stun:stun.example.com"], username: nil, credential: nil)
        let options = ConnectOptions(iceServers: [server])
        XCTAssertEqual(options.iceServers.count, 1)
    }

    func testCustomIceTransportPolicy() {
        let options = ConnectOptions(iceTransportPolicy: .relay)
        XCTAssertEqual(options.iceTransportPolicy, .relay)
    }

    func testDscpEnabled() {
        let options = ConnectOptions(isDscpEnabled: true)
        XCTAssertTrue(options.isDscpEnabled)
    }

    func testEnableMicrophone() {
        let options = ConnectOptions(enableMicrophone: true)
        XCTAssertTrue(options.enableMicrophone)
    }
}
