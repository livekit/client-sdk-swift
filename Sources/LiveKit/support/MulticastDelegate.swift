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

// protocol MulticastDelegate {
//    associatedtype DelegateType
//    var delegates: NSHashTable<AnyObject> { get }
// }
//
// extension MulticastDelegate {
//
//    func add(delegate: DelegateType) {
//
//        guard let delegate = delegate as AnyObject? else {
//            logger.debug("delegate is not an AnyObject")
//            return
//        }
//
//        delegates.add(delegate as AnyObject)
//    }
//
//    func remove(delegate: DelegateType) {
//
//        guard let delegate = delegate as AnyObject? else {
//            logger.debug("delegate is not an AnyObject")
//            return
//        }
//
//        delegates.remove(delegate as AnyObject)
//    }
//
//    // notify delegates
//    internal func notify(_ fnc: (DelegateType) throws -> Void) rethrows {
//
//        for d in delegates.objectEnumerator() {
//            guard let d = d as? DelegateType else {
//                logger.debug("notify() delegate is not type of \(DelegateType.self)")
//                continue
//            }
//            try fnc(d)
//        }
//    }
// }

// extension Array where Element == MulticastDelegate<Any> {
//
//    func wait<T>(timeout: TimeInterval,
//                  onTimeout: Error = InternalError.timeout(),
//                  builder: (@escaping (T) -> Void) -> Element.DelegateType) -> Promise<T> {
//
//        let promise = Promise<T>.pending()
//        var timer: DispatchWorkItem?
//        var delegate: Element.T?
//
//        let completeFnc: (T) -> Void = { value in
//            // cancel timer
//            timer?.cancel()
//
//            // stop listening
//            logger.debug("[MulticastDelegate] removing temporary delegate")
//            for multicast in self {
//                multicast.remove(delegate: delegate!)
//            }
//
//            promise.fulfill(value)
//        }
//
//        let failFnc = {
//            // stop listening
//            logger.debug("[MulticastDelegate] removing temporary delegate")
//            for multicast in self {
//                multicast.remove(delegate: delegate!)
//            }
//
//            promise.reject(onTimeout)
//        }
//
//        delegate = builder(completeFnc)
//
//        logger.debug("[MulticastDelegate] adding temporary delegate")
//        // start listening
//        for multicast in self {
//            multicast.add(delegate: delegate!)
//            logger.debug("[MulticastDelegate] \(multicast.self) delegates count: \(multicast.delegates.count)")
//        }
//
//
//        // start timer
//        timer = DispatchWorkItem() { failFnc() }
//        DispatchQueue.main.asyncAfter(deadline: .now() + timeout,
//                                      execute: timer!)
//
//        return promise
//    }
// }
