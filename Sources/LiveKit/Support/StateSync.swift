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

import Combine
import Foundation
import os.lock

public typealias OnStateDidMutate<State> = (_ newState: State, _ oldState: State) -> Void

protocol Lockable {
    associatedtype State
    var onDidMutate: OnStateDidMutate<State>? { get set }
    init(_ state: State, onDidMutate: OnStateDidMutate<State>?)
    func copy() -> State
    func mutate<Result>(_ block: (inout State) throws -> Result) rethrows -> Result
    func read<Result>(_ block: (State) throws -> Result) rethrows -> Result
    subscript<Property>(dynamicMember _: KeyPath<State, Property>) -> Property { get }
}

@dynamicMemberLookup
public final class StateSync<State>: Lockable {
    // MARK: - Public

    public var onDidMutate: OnStateDidMutate<State>? {
        get { _lock.sync { _onDidMutate } }
        set { _lock.sync { _onDidMutate = newValue } }
    }

    // MARK: - Private

    private var _state: State
    private let _lock = UnfairLock()
    private var _onDidMutate: OnStateDidMutate<State>?

    public init(_ state: State, onDidMutate: OnStateDidMutate<State>? = nil) {
        _state = state
        _onDidMutate = onDidMutate
    }

    // mutate sync
    @discardableResult
    public func mutate<Result>(_ block: (inout State) throws -> Result) rethrows -> Result {
        try _lock.sync {
            let oldState = _state
            let result = try block(&_state)
            let newState = _state

            // Always invoke onDidMutate within the lock (sync) since
            // logic following the state mutation may depend on this.
            // Invoke on async queue within _onDidMutate if necessary.
            _onDidMutate?(newState, oldState)

            return result
        }
    }

    // read sync and return copy
    public func copy() -> State {
        _lock.sync { _state }
    }

    // read with block
    public func read<Result>(_ block: (State) throws -> Result) rethrows -> Result {
        try _lock.sync { try block(_state) }
    }

    // property read sync
    public subscript<Property>(dynamicMember keyPath: KeyPath<State, Property>) -> Property {
        _lock.sync { _state[keyPath: keyPath] }
    }
}

extension StateSync: CustomStringConvertible {
    public var description: String {
        "StateSync(\(String(describing: copy()))"
    }
}

@available(macOS 13.0, iOS 16.0, *)
@dynamicMemberLookup
private class InternalOSLock<State>: Lockable {
    // ...
    struct WrappedState {
        var state: State
        var onDidMutate: OnStateDidMutate<State>?
    }

    public var onDidMutate: OnStateDidMutate<State>? {
        get { _lock.withLockUnchecked { $0.onDidMutate } }
        set { _lock.withLockUnchecked { $0.onDidMutate = newValue } }
    }

    private let _lock: OSAllocatedUnfairLock<WrappedState>
    private var _onDidMutate: OnStateDidMutate<State>?

    required init(_ state: State, onDidMutate: OnStateDidMutate<State>?) {
        _lock = OSAllocatedUnfairLock(uncheckedState: WrappedState(state: state, onDidMutate: onDidMutate))
    }

    func copy() -> State {
        _lock.withLockUnchecked { $0.state }
    }

    func mutate<Result>(_ block: (inout State) throws -> Result) rethrows -> Result {
        try _lock.withLockUnchecked { try block(&$0.state) }
    }

    func read<Result>(_ block: (State) throws -> Result) rethrows -> Result {
        try _lock.withLockUnchecked { try block($0.state) }
    }

    subscript<Property>(dynamicMember keyPath: KeyPath<State, Property>) -> Property {
        _lock.withLockUnchecked { $0.state[keyPath: keyPath] }
    }
}

@dynamicMemberLookup
public final class StateSync2<State> {
    // MARK: - Public

    public var onDidMutate: OnStateDidMutate<State>? {
        get { fatalError() }
        set { fatalError() }
    }

    // MARK: - Private

    private let _lock: any Lockable

    public init(_ state: State, onDidMutate: OnStateDidMutate<State>?) {
        if #available(macOS 13.0, iOS 16.0, *) {
            _lock = InternalOSLock<State>(state, onDidMutate: onDidMutate)
        } else {
            // Fallback on earlier versions
            fatalError()
        }
    }

    // mutate sync
    @discardableResult
    public func mutate<Result>(_ block: (inout State) throws -> Result) rethrows -> Result {
        _lock.mutate(block)
    }

    // read sync and return copy
    public func copy() -> State {
        _lock.copy()
    }

    // read with block
    public func read<Result>(_ block: (State) throws -> Result) rethrows -> Result {
        try _lock.read(block)
    }

    // property read sync
    public subscript<Property>(dynamicMember keyPath: KeyPath<State, Property>) -> Property {
        _lock[keyPath: keyPath]
    }
}
