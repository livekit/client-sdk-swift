/*
 * Copyright 2025 LiveKit
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
public class MulticastDelegate<T: Sendable>: NSObject, @unchecked Sendable, Loggable {
    // MARK: - Public properties

    public var isDelegatesEmpty: Bool { countDelegates == 0 }

    public var isDelegatesNotEmpty: Bool { countDelegates != 0 }

    /// `NSHashTable` may not immediately deinit the un-referenced object, due to Apple's implementation, therefore ``countDelegates`` may be unreliable.
    public var countDelegates: Int {
        _state.read { $0.delegates.allObjects.count }
    }

    public var allDelegates: [T] {
        _state.read { $0.delegates.allObjects.compactMap { $0 as? T } }
    }

    // MARK: - Private properties

    private struct State {
        let delegates = NSHashTable<AnyObject>.weakObjects()
    }

    private let _queue: DispatchQueue

    private let _state = StateSync(State())

    init(label: String, qos: DispatchQoS = .default) {
        _queue = DispatchQueue(label: "LiveKitSDK.Multicast.\(label)", qos: qos, attributes: [])
    }

    /// Add a single delegate.
    public func add(delegate: T) {
        guard let delegate = delegate as AnyObject? else {
            log("MulticastDelegate: delegate is not an AnyObject")
            return
        }

        _state.mutate { $0.delegates.add(delegate) }
    }

    /// Remove a single delegate.
    ///
    /// In most cases this is not required to be called explicitly since all delegates are weak.
    public func remove(delegate: T) {
        guard let delegate = delegate as AnyObject? else {
            log("MulticastDelegate: delegate is not an AnyObject")
            return
        }

        _state.mutate { $0.delegates.remove(delegate) }
    }

    /// Remove all delegates.
    public func removeAllDelegates() {
        _state.mutate { $0.delegates.removeAllObjects() }
    }

    /// Notify delegates inside the queue.
    func notify(label _: (() -> String)? = nil, _ fnc: @Sendable @escaping (T) -> Void) {
        let delegates = _state.read { $0.delegates.allObjects.compactMap { $0 as? T } }

        _queue.async {
            for delegate in delegates {
                fnc(delegate)
            }
        }
    }

    /// Awaitable version of notify
    func notifyAsync(_ fnc: @Sendable @escaping (T) -> Void) async {
        // Read a copy of delegates
        let delegates = _state.read { $0.delegates.allObjects.compactMap { $0 as? T } }

        // Convert to async
        await withCheckedContinuation { continuation in
            _queue.async {
                for delegate in delegates {
                    fnc(delegate)
                }
                continuation.resume()
            }
        }
    }
}
