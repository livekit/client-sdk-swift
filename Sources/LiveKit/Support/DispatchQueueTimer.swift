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

internal class DispatchQueueTimer: Loggable {

    public enum State {
        case suspended
        case resumed
    }

    private let queue: DispatchQueue?
    private let timeInterval: TimeInterval
    private var timer: DispatchSourceTimer!
    public var handler: (() -> Void)?
    public private(set) var state: State = .suspended

    public init(timeInterval: TimeInterval, queue: DispatchQueue? = nil) {
        self.timeInterval = timeInterval
        self.queue = queue
        self.timer = createTimer()
    }

    deinit {
        cleanUpTimer()
        handler = nil
    }

    // reset the state
    public func reset() {
        cleanUpTimer()
        timer = createTimer()
        state = .suspended
    }

    public func restart() {
        reset()
        resume()
    }

    // continue from where it was suspended
    public func resume() {
        if state == .resumed {
            return
        }
        state = .resumed
        timer.resume()
    }

    public func suspend() {
        if state == .suspended {
            return
        }
        state = .suspended
        timer.suspend()
    }

    private func createTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + self.timeInterval, repeating: self.timeInterval)
        timer.setEventHandler { [weak self] in self?.handler?() }
        return timer
    }

    private func cleanUpTimer() {
        timer.setEventHandler {}
        timer.cancel()
        /*
         If the timer is suspended, calling cancel without resuming
         triggers a crash. This is documented here https://forums.developer.apple.com/thread/15902
         */
        resume()
    }
}
