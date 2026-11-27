/*
 * Copyright 2026 LiveKit
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

/// The observer-free subset of StateSync used by the socket. All state access holds the lock.
@dynamicMemberLookup
final class StateSync<State>: @unchecked Sendable {
    private var state: State
    private let lock: some Lock = createLock()

    init(_ state: State) { self.state = state }

    @discardableResult
    func mutate<Result>(_ block: (inout State) throws -> Result) rethrows -> Result {
        try lock.sync { try block(&state) }
    }

    @discardableResult
    func mutateWithoutObservation<Result>(_ block: (inout State) throws -> Result) rethrows -> Result {
        try mutate(block)
    }

    func read<Result>(_ block: (State) throws -> Result) rethrows -> Result {
        try lock.sync { try block(state) }
    }

    func copy() -> State { read { $0 } }

    subscript<Property>(dynamicMember keyPath: KeyPath<State, Property>) -> Property {
        read { $0[keyPath: keyPath] }
    }
}
