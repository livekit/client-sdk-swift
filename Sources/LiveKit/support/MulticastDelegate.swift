import Foundation
import Promises

// simplify generic constraints but check type at add/remove
public class MulticastDelegate<T>: NSObject {

    private let lock = NSLock()
    private let set = NSHashTable<AnyObject>.weakObjects()

    func add(delegate: T) {

        guard let delegate = delegate as AnyObject? else {
            logger.debug("delegate is not an AnyObject")
            return
        }

        lock.lock()
        defer { lock.unlock() }

        self.set.add(delegate)
        logger.debug("[\(self) MulticastDelegate] count updated: \(self.set.count)")
    }

    // in most cases this is not required to be called since all delegates are weak
    func remove(delegate: T) {

        guard let delegate = delegate as AnyObject? else {
            logger.debug("delegate is not an AnyObject")
            return
        }

        lock.lock()
        defer { lock.unlock() }

        self.set.remove(delegate)
        logger.debug("[\(self) MulticastDelegate] count updated: \(self.set.count)")
    }

    internal func notify(_ fnc: @escaping (T) throws -> Void) rethrows {

        guard set.count != 0 else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        for delegate in self.set.objectEnumerator() {
            guard let delegate = delegate as? T else {
                logger.debug("notify() delegate is not type of \(T.self)")
                continue
            }
            try fnc(delegate)
        }
    }

    //    internal func wait<V>(timeout: TimeInterval,
    //                  onTimeout: Error = InternalError.timeout(),
    //                  builder: (@escaping (V) -> Void) -> T) -> Promise<V> {
    //
    //        let promise = Promise<V>.pending()
    //        var timer: DispatchWorkItem?
    //        var delegate: T?
    //
    //        let completeFnc: (V) -> Void = { value in
    //            // cancel timer
    //            timer?.cancel()
    //            promise.fulfill(value)
    //            // stop listening
    //            DispatchQueue.main.async {
    //                self.remove(delegate: delegate!)
    //            }
    //        }
    //
    //        let failFnc = {
    //            promise.reject(onTimeout)
    //            // stop listening
    //            DispatchQueue.main.async {
    //                self.remove(delegate: delegate!)
    //            }
    //        }
    //
    //        delegate = builder(completeFnc)
    //        add(delegate: delegate!)
    //
    //        // start timer
    //        logger.debug("[MulticastDelegate] started timer")
    //        timer = DispatchWorkItem() { failFnc() }
    //        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer!)
    //
    //        return promise
    //    }
}
