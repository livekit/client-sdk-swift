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

@testable import LiveKit
import XCTest

class DeviceManagerTests: LKTestCase {
    func testListDevices() async throws {
        let devices = try await DeviceManager.shared.devices()
        print("Devices: \(devices.map { "(facingPosition: \(String(describing: $0.facingPosition)))" }.joined(separator: ", "))")
        XCTAssert(devices.count > 0, "No capture devices found.")

        // visionOS will return 0 formats.
        guard let firstDevice = devices.first else { return }
        let formats = firstDevice.formats
        XCTAssert(formats.count > 0, "No formats found for device.")
    }
}
