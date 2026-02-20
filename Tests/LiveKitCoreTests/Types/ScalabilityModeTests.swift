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

class ScalabilityModeTests: LKTestCase {
    // MARK: - fromString Parsing

    func testFromStringL3T3() {
        let mode = ScalabilityMode.fromString("L3T3")
        XCTAssertEqual(mode, .L3T3)
    }

    func testFromStringL3T3KEY() {
        let mode = ScalabilityMode.fromString("L3T3_KEY")
        XCTAssertEqual(mode, .L3T3_KEY)
    }

    func testFromStringL3T3KEYSHIFT() {
        let mode = ScalabilityMode.fromString("L3T3_KEY_SHIFT")
        XCTAssertEqual(mode, .L3T3_KEY_SHIFT)
    }

    func testFromStringL1T3() {
        let mode = ScalabilityMode.fromString("L1T3")
        XCTAssertEqual(mode, .L1T3)
    }

    func testFromStringNil() {
        XCTAssertNil(ScalabilityMode.fromString(nil))
    }

    func testFromStringEmpty() {
        XCTAssertNil(ScalabilityMode.fromString(""))
    }

    func testFromStringInvalid() {
        XCTAssertNil(ScalabilityMode.fromString("L2T2"))
        XCTAssertNil(ScalabilityMode.fromString("invalid"))
        XCTAssertNil(ScalabilityMode.fromString("l3t3")) // case-sensitive
    }

    // MARK: - rawStringValue

    func testRawStringValueRoundtrip() {
        let modes: [ScalabilityMode] = [.L3T3, .L3T3_KEY, .L3T3_KEY_SHIFT, .L1T3]
        for mode in modes {
            XCTAssertEqual(ScalabilityMode.fromString(mode.rawStringValue), mode,
                           "Round-trip failed for \(mode)")
        }
    }

    // MARK: - Spatial and Temporal Layers

    func testSpatialL1T3() {
        XCTAssertEqual(ScalabilityMode.L1T3.spatial, 1)
    }

    func testSpatialL3T3() {
        XCTAssertEqual(ScalabilityMode.L3T3.spatial, 3)
    }

    func testSpatialL3T3KEY() {
        XCTAssertEqual(ScalabilityMode.L3T3_KEY.spatial, 3)
    }

    func testSpatialL3T3KEYSHIFT() {
        XCTAssertEqual(ScalabilityMode.L3T3_KEY_SHIFT.spatial, 3)
    }

    func testTemporalIsAlways3() {
        let modes: [ScalabilityMode] = [.L3T3, .L3T3_KEY, .L3T3_KEY_SHIFT, .L1T3]
        for mode in modes {
            XCTAssertEqual(mode.temporal, 3, "Temporal should be 3 for \(mode)")
        }
    }

    // MARK: - Description

    func testDescription() {
        XCTAssertEqual(ScalabilityMode.L3T3.description, "ScalabilityMode(L3T3)")
        XCTAssertEqual(ScalabilityMode.L1T3.description, "ScalabilityMode(L1T3)")
    }
}
