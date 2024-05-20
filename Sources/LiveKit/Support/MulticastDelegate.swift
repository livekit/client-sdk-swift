/*
 * Copyright 2024 LiveKit
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
    private let _queue: DispatchQueue
    private let _set = NSHashTable<AnyObject>.weakObjects()

    init(label: String, qos: DispatchQoS = .default) {
        _queue = DispatchQueue(label: "LiveKitSDK.Multicast.\(label)", qos: qos, attributes: [])
    }

    public var isDelegatesEmpty: Bool { countDelegates == 0 }
    public var isDelegatesNotEmpty: Bool { countDelegates != 0 }

    public var countDelegates: Int {
        _queue.sync { [weak self] in
            guard let self else { return 0 }
            return self._set.allObjects.count
        }
    }

    public var allDelegates: [T] {
        _queue.sync { [weak self] in
            guard let self else { return [] }
            return self._set.allObjects.compactMap { $0 as? T }
        }
    }

    /// Add a single delegate.
    public func add(delegate: T) {
        guard let delegate = delegate as AnyObject? else {
            log("MulticastDelegate: delegate is not an AnyObject")
            return
        }

        _queue.sync { [weak self] in
            guard let self else { return }
            self._set.add(delegate)
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

        _queue.sync { [weak self] in
            guard let self else { return }
            self._set.remove(delegate)
        }
    }

    /// Remove all delegates.
    public func removeAllDelegates() {
        _queue.sync { [weak self] in
            guard let self else { return }
            self._set.removeAllObjects()
        }
    }

    /// Notify delegates inside the queue.
    /// Label is captured inside the queue for thread safety reasons.
    func notify(label: (() -> String)? = nil, _ fnc: @escaping (T) -> Void) {
        _queue.async {
            if let label {
                self.log("[notify] \(label())", .trace)
            }

            let delegates = self._set.allObjects.compactMap { $0 as? T }

            for delegate in delegates {
                fnc(delegate)
            }
        }
    }
}
