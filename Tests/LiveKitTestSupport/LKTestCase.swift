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

import LiveKit
import LiveKitWebRTC
@_exported import XCTest

/// Subclass of XCTestCase that performs global initialization.
open class LKTestCase: XCTestCase {
    override open func setUp() {
        LiveKitSDK.setLogLevel(.info)
        continueAfterFailure = false // Fail early
        super.setUp()
    }
}

public extension LKTestCase {
    func sleep(forSeconds seconds: UInt) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }
}
