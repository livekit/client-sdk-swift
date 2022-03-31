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
import Promises

/// A class that allows to have multiple delegates instead of one.
///
/// Uses `NSHashTable` internally to maintain a set of weak delegates.
///
/// > Note: `NSHashTable` may not immediately deinit the un-referenced object, due to Apple's implementation, therefore `.count` is unreliable.
public class MulticastDelegate<T>: NSObject, Loggable {

    internal let multicastQueue: DispatchQueue
    private let set = NSHashTable<AnyObject>.weakObjects()

    init(label: String = "livekit.multicast", qos: DispatchQoS = .default) {
        self.multicastQueue = DispatchQueue(label: label, qos: qos)
    }

    /// Add a single delegate.
    public func add(delegate: T) {

        guard let delegate = delegate as AnyObject? else {
            log("MulticastDelegate: delegate is not an AnyObject")
            return
        }

        multicastQueue.sync { set.add(delegate) }
    }

    /// Remove a single delegate.
    ///
    /// In most cases this is not required to be called explicitly since all delegates are weak.
    public func remove(delegate: T) {

        guard let delegate = delegate as AnyObject? else {
            log("MulticastDelegate: delegate is not an AnyObject")
            return
        }

        multicastQueue.sync { set.remove(delegate) }
    }

    internal func notify(_ fnc: @escaping (T) -> Void) {

        multicastQueue.async {
            for delegate in self.set.allObjects {
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

        multicastQueue.async {
            var isHandled: Bool = false
            for delegate in self.set.allObjects {
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
