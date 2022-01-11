import Foundation
import Promises

/// A class that allows to have multiple delegates instead of one.
///
/// Uses `NSHashTable` internally to maintain a set of weak delegates.
///
/// > Note: `NSHashTable` may not immediately deinit the un-referenced object, due to Apple's implementation.
public class MulticastDelegate<T>: NSObject {

    private let queue = DispatchQueue(label: "livekit.multicast")
    private let set = NSHashTable<AnyObject>.weakObjects()

    /// Add a single delegate.
    public func add(delegate: T) {

        guard let delegate = delegate as AnyObject? else {
            logger.debug("MulticastDelegate: delegate is not an AnyObject")
            return
        }

        queue.sync { set.add(delegate) }
    }

    /// Remove a single delegate.
    ///
    /// In most cases this is not required to be called explicitly since all delegates are weak.
    public func remove(delegate: T) {

        guard let delegate = delegate as AnyObject? else {
            logger.debug("MulticastDelegate: delegate is not an AnyObject")
            return
        }

        queue.sync { set.remove(delegate) }
    }

    internal func notify(_ fnc: @escaping (T) throws -> Void) rethrows {

        guard set.count != 0 else { return }

        try queue.sync {
            for delegate in set.objectEnumerator() {
                guard let delegate = delegate as? T else {
                    logger.debug("MulticastDelegate: skipping notify for \(delegate), not a type of \(T.self)")
                    continue
                }
                try fnc(delegate)
            }
        }
    }
}

public protocol MulticastDelegateCapable {
    associatedtype DelegateType
    var delegates: MulticastDelegate<DelegateType> { get }
    func add(delegate: DelegateType)
    func remove(delegate: DelegateType)
    func notify(_ fnc: @escaping (DelegateType) throws -> Void) rethrows
}

extension MulticastDelegateCapable {

    public func add(delegate: DelegateType) {
        delegates.add(delegate: delegate)
    }

    public func remove(delegate: DelegateType) {
        delegates.remove(delegate: delegate)
    }

    public func notify(_ fnc: @escaping (DelegateType) throws -> Void) rethrows {
        try delegates.notify(fnc)
    }
}
