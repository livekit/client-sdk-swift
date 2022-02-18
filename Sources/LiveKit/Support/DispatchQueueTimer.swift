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
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + self.timeInterval, repeating: self.timeInterval)
        t.setEventHandler(handler: { [weak self] in
            self?.handler?()
        })
        return t
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
