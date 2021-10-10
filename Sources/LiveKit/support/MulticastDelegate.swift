import Foundation
import Promises

protocol MulticastDelegate {
    associatedtype DelegateType
    var delegates: NSHashTable<AnyObject> { get }
}

extension MulticastDelegate {

    func add(delegate: DelegateType) {
        guard let delegate = delegate as AnyObject? else {
            logger.debug("delegate is not an AnyObject")
            return
        }

        delegates.add(delegate as AnyObject)
    }

    func remove(delegate: DelegateType) {
        guard let delegate = delegate as AnyObject? else {
            logger.debug("delegate is not an AnyObject")
            return
        }

        delegates.remove(delegate as AnyObject)
    }

    // notify delegates
    internal func notify(_ fnc: (DelegateType) throws -> Void) rethrows {
        for d in delegates.objectEnumerator() {
            guard let d = d as? DelegateType else {
                logger.debug("notify() delegate is not type of \(DelegateType.self)")
                continue
            }
            try fnc(d)
        }
    }
}

extension Array where Element: MulticastDelegate {

    func wait<T>(timeout: TimeInterval,
                  onTimeout: Error = InternalError.timeout(),
                  builder: (@escaping (T) -> Void) -> Element.DelegateType) -> Promise<T> {

        let promise = Promise<T>.pending()
        var timer: DispatchWorkItem?
        var delegate: Element.DelegateType?

        let completeFnc: (T) -> Void = { [weak promise] value in
            // cancel timer
            timer?.cancel()

            // stop listening
            logger.debug("[MulticastDelegate] removing temporary delegate")
            for multicast in self {
                multicast.remove(delegate: delegate!)
            }

            promise?.fulfill(value)
        }

        let failFnc = { [weak promise] in
            // stop listening
            logger.debug("[MulticastDelegate] removing temporary delegate")
            for multicast in self {
                multicast.remove(delegate: delegate!)
            }

            promise?.reject(onTimeout)
        }

        delegate = builder(completeFnc)

        logger.debug("[MulticastDelegate] adding temporary delegate")
        // start listening
        for multicast in self {
            multicast.add(delegate: delegate!)
        }

        // start timer
        timer = DispatchWorkItem() { failFnc() }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout,
                                      execute: timer!)

        return promise
    }
}
