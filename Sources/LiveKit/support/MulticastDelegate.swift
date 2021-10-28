import Foundation
import Promises

/// A class that allows to have multiple delegates instead of one.
///
/// Uses `NSHashTable` internally to maintain a set of weak delegates.
///
/// > Note: `NSHashTable` may not immediately deinit the un-referenced object, due to Apple's implementation.
public class MulticastDelegate<T>: NSObject {

    private let lock = NSLock()
    private let set = NSHashTable<AnyObject>.weakObjects()

    /// Add a single delegate.
    public func add(delegate: T) {

        guard let delegate = delegate as AnyObject? else {
            logger.debug("delegate is not an AnyObject")
            return
        }

        lock.lock()
        defer { lock.unlock() }

        self.set.add(delegate)
        logger.debug("[\(self) MulticastDelegate] count updated: \(self.set.count)")
    }

    /// Remove a single delegate.
    ///
    /// In most cases this is not required to be called explicitly since all delegates are weak.
    public func remove(delegate: T) {

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
}
