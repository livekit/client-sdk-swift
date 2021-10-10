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

    func wait(timeout: TimeInterval,
                  onTimeout: Error = InternalError.timeout(),
                  builder: (@escaping () -> Void) -> Element.DelegateType) -> Promise<Void> {

        let promise = Promise<Void>.pending()
        var timer: DispatchWorkItem?
        var delegate: Element.DelegateType?

        let fulfill = { [weak promise] in
            // cancel timer
            timer?.cancel()

            // stop listening
            for multicast in self {
                multicast.remove(delegate: delegate!)
            }

            promise?.fulfill(())
        }

        let reject = { [weak promise] in
            // stop listening
            for multicast in self {
                multicast.remove(delegate: delegate!)
            }

            promise?.reject(onTimeout)
        }

        delegate = builder(fulfill)


        // start listening
        for multicast in self {
            multicast.add(delegate: delegate!)
        }

        // start timer
        timer = DispatchWorkItem() { reject() }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout,
                                      execute: timer!)

        return promise
    }
}
