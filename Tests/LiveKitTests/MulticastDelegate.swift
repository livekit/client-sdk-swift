/*
 * Copyright 2024 LiveKit
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

protocol TestDelegate: AnyObject {
    func onDelegateMethod()
}

class MulticastDelegates: XCTestCase {
    // Test if each delegate method gets invoked concurrently
    func testBlockingDelegate() async {
        let d = MulticastDelegate<TestDelegate>(label: "test delegate")
        let q1 = QuickDelegate(label: "#1")
        let q2 = QuickDelegate(label: "#2")
        let q3 = QuickDelegate(label: "#3")
        let b1 = BlockingDelegate(label: "#1, 3sec", sleepSecs: 3)
        let b2 = BlockingDelegate(label: "#2, 2sec", sleepSecs: 2)

        d.add(delegate: q1)
        d.add(delegate: b2)
        d.add(delegate: q2)
        d.add(delegate: b1)
        d.add(delegate: q3)

        print("Invoking delegates...")
        await d.notifyAsync { $0.onDelegateMethod() }
        print("All delegates completed")
    }

    func testNestedCalls() async {
        func methodA() {}
        func methodB() {}
    }
}

class QuickDelegate: TestDelegate {
    let label: String
    init(label: String) {
        self.label = label
    }

    func onDelegateMethod() {
        print("QuickDelegate(\(label)).onDelegateMethod")
    }
}

class BlockingDelegate: TestDelegate {
    let label: String
    let sleepSecs: UInt32
    init(label: String, sleepSecs: UInt32) {
        self.label = label
        self.sleepSecs = sleepSecs
    }

    func onDelegateMethod() {
        sleep(sleepSecs)
        print("BlockingDelegate(\(label)).onDelegateMethod")
    }
}
