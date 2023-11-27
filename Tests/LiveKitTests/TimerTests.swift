/*
 * Copyright 2022 LiveKit
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
import Promises

class TimerTests: XCTestCase {

    let timer = DispatchQueueTimer(timeInterval: 1)
    var counter = 0

    func testSuspendRestart() async throws {
    
        timer.resume()
        
        await withCheckedContinuation({ (continuation: CheckedContinuation<Void, Never>) in
            //
            timer.handler = {
                print("onTimer count: \(self.counter)")
                
                self.counter += 1

                if self.counter == 3 {
                    print("suspending timer for 3s...")
                    self.timer.suspend()
                    Promise(()).delay(3).then {
                        print("restarting timer...")
                        self.timer.restart()
                    }
                }
                
                if self.counter == 5 {
                    continuation.resume()
                }
            }
        })
    }
}
