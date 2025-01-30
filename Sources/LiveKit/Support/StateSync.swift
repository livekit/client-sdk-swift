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

import Combine
import Foundation

@dynamicMemberLookup
public final class StateSync<State>: @unchecked Sendable {
    // MARK: - Types

    public typealias OnDidMutate = (_ newState: State, _ oldState: State) -> Void

    // MARK: - Public

    public var onDidMutate: OnDidMutate? {
        get { _lock.sync { _onDidMutate } }
        set { _lock.sync { _onDidMutate = newValue } }
    }

    // MARK: - Private

    private var _state: State
    private let _lock = UnfairLock()
    private var _onDidMutate: OnDidMutate?

    public init(_ state: State, onDidMutate: OnDidMutate? = nil) {
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
