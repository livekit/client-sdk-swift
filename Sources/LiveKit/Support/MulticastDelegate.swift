import Foundation
import Promises

/// A class that allows to have multiple delegates instead of one.
///
/// Uses `NSHashTable` internally to maintain a set of weak delegates.
///
/// > Note: `NSHashTable` may not immediately deinit the un-referenced object, due to Apple's implementation, therefore `.count` is unreliable.
public class MulticastDelegate<T>: NSObject, Loggable {

    private let queue = DispatchQueue(label: "livekit.multicast")
    private let set = NSHashTable<AnyObject>.weakObjects()

    /// Add a single delegate.
    public func add(delegate: T) {

        guard let delegate = delegate as AnyObject? else {
            log("MulticastDelegate: delegate is not an AnyObject")
            return
        }

        queue.sync { set.add(delegate) }
    }

    /// Remove a single delegate.
    ///
    /// In most cases this is not required to be called explicitly since all delegates are weak.
    public func remove(delegate: T) {

        guard let delegate = delegate as AnyObject? else {
            log("MulticastDelegate: delegate is not an AnyObject")
            return
        }

        queue.sync { set.remove(delegate) }
    }

    internal func notify(_ fnc: @escaping (T) -> Void) {

        queue.async {
            for delegate in self.set.objectEnumerator() {
                guard let delegate = delegate as? T else {
                    self.log("MulticastDelegate: skipping notify for \(delegate), not a type of \(T.self)", .info)
                    continue
                }

                fnc(delegate)
            }
        }
    }

    /// At least one delegate must return `true`, otherwise a `warning` will be logged
    internal func notify(_ fnc: @escaping (T) -> Bool,
                         function: String = #function,
                         line: UInt = #line) {

        queue.async {
            var isHandled: Bool = false
            for delegate in self.set.objectEnumerator() {
                guard let delegate = delegate as? T else {
                    self.log("MulticastDelegate: skipping notify for \(delegate), not a type of \(T.self)", .info)
                    continue
                }

                if fnc(delegate) { isHandled = true }
            }

            if !isHandled {
                self.log("Notify was not handled, called from \(function) line \(line)", .warning)
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

    public func notify(_ fnc: @escaping (DelegateType) -> Void) {
        delegates.notify(fnc)
    }
}
