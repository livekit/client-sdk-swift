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

// Workaround for Swift-ObjC limitation around generics.
public protocol MulticastDelegateProtocol {
    associatedtype Delegate
    func add(delegate: Delegate)
    func remove(delegate: Delegate)
    func removeAllDelegates()
}

/// A class that allows to have multiple delegates instead of one.
///
/// Uses `NSHashTable` internally to maintain a set of weak delegates.
///
/// > Note: `NSHashTable` may not immediately deinit the un-referenced object, due to Apple's implementation, therefore `.count` is unreliable.
public class MulticastDelegate<T>: NSObject, Loggable {

    internal let multicastQueue: DispatchQueue
    private let set = NSHashTable<AnyObject>.weakObjects()

    init(label: String = "livekit.multicast", qos: DispatchQoS = .default) {
        self.multicastQueue = DispatchQueue(label: label, qos: qos, attributes: [])
    }

    /// Add a single delegate.
    public func add(delegate: T) {

        guard let delegate = delegate as AnyObject? else {
            log("MulticastDelegate: delegate is not an AnyObject")
            return
        }

        multicastQueue.sync { [weak self] in
            guard let self = self else { return }
            self.set.add(delegate)
        }
    }

    /// Remove a single delegate.
    ///
    /// In most cases this is not required to be called explicitly since all delegates are weak.
    public func remove(delegate: T) {

        guard let delegate = delegate as AnyObject? else {
            log("MulticastDelegate: delegate is not an AnyObject")
            return
        }

        multicastQueue.sync { [weak self] in
            guard let self = self else { return }
            self.set.remove(delegate)
        }
    }

    /// Remove all delegates.
    public func removeAllDelegates() {

        multicastQueue.sync { [weak self] in
            guard let self = self else { return }
            self.set.removeAllObjects()
        }
    }

    /// Notify delegates inside the queue.
    /// Label is captured inside the queue for thread safety reasons.
    internal func notify(label: (() -> String)? = nil, _ fnc: @escaping (T) -> Void) {

        multicastQueue.async {

            if let label = label {
                self.log("[notify] \(label())", .debug)
            }

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
    /// returns true if was handled by at least one delegate
    internal func notify(requiresHandle: Bool = true,
                         function: String = #function,
                         line: UInt = #line,
                         label: (() -> String)? = nil,
                         _ fnc: @escaping (T) -> Bool) {

        multicastQueue.async {

            if let label = label {
                self.log("[notify] \(label())", .debug)
            }

            var counter: Int = 0
            for delegate in self.set.allObjects {
                guard let delegate = delegate as? T else {
                    self.log("MulticastDelegate: skipping notify for \(delegate), not a type of \(T.self)", .info)
                    continue
                }

                if fnc(delegate) { counter += 1 }
            }

            let wasHandled = counter > 0
            if !(requiresHandle && !wasHandled) {
                self.log("notify() was not handled by the delegate, called from \(function) line \(line)", .warning)
            }
        }
    }
}
