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

    typealias OnTimer = (() -> Void)

    public enum State {
        case suspended
        case resumed
    }

    private let _queue: DispatchQueue?
    private let _timeInterval: TimeInterval
    private var _timer: DispatchSourceTimer!
    private var _state: State = .suspended
    private var _handler: OnTimer?

    private let _lock = UnfairLock()

    public init(timeInterval: TimeInterval, queue: DispatchQueue? = nil) {
        _timeInterval = timeInterval
        _queue = queue
        _timer = _createTimer()
    }

    deinit {
        _cleanUpTimer()
        _handler = nil
    }

    // MARK: - Public

    public func setOnTimer(_ block: @escaping OnTimer) {
        _lock.sync {
            _handler = block
        }
    }

    public func resume() {
        _lock.sync {
            _resume()
        }
    }

    public func suspend() {
        _lock.sync {
            _suspend()
        }
    }

    public func restart() {
        _lock.sync {
            _restart()
        }
    }

    // MARK: - Private

    private func _reset() {
        _cleanUpTimer()
        _timer = _createTimer()
        _state = .suspended
    }

    private func _restart() {
        _reset()
        _resume()
    }

    private func _resume() {
        if _state == .resumed { return }
        _state = .resumed
        _timer.resume()
    }

    private func _suspend() {
        if _state == .suspended { return }
        _state = .suspended
        _timer.suspend()
    }

    private func _createTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: _queue)
        timer.schedule(deadline: .now() + self._timeInterval, repeating: self._timeInterval)
        timer.setEventHandler { [weak self] in self?._handler?() }
        return timer
    }

    private func _cleanUpTimer() {
        _timer.setEventHandler {}
        _timer.cancel()
        /*
         If the timer is suspended, calling cancel without resuming
         triggers a crash. This is documented here https://forums.developer.apple.com/thread/15902
         */
        _resume()
    }
}
