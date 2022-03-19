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

import Foundation

internal class DispatchQueueTimer {

    public enum State {
        case suspended
        case resumed
    }

    private let queue: DispatchQueue?
    private let timeInterval: TimeInterval

    init(timeInterval: TimeInterval, queue: DispatchQueue? = nil) {
        self.timeInterval = timeInterval
        self.queue = queue
    }

    private lazy var timer: DispatchSourceTimer = {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + self.timeInterval, repeating: self.timeInterval)
        timer.setEventHandler(handler: { [weak self] in self?.handler?() })
        return timer
    }()

    var handler: (() -> Void)?

    public private(set) var state: State = .suspended

    deinit {
        timer.setEventHandler {}
        timer.cancel()
        /*
         If the timer is suspended, calling cancel without resuming
         triggers a crash. This is documented here https://forums.developer.apple.com/thread/15902
         */
        resume()
        handler = nil
    }

    func resume() {
        if state == .resumed {
            return
        }
        state = .resumed
        timer.resume()
    }

    func suspend() {
        if state == .suspended {
            return
        }
        state = .suspended
        timer.suspend()
    }
}
