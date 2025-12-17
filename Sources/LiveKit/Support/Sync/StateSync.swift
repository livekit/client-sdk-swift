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

#if LK_SIGNPOSTS
import os.signpost
#endif

@dynamicMemberLookup
public final class StateSync<State>: @unchecked Sendable, Loggable {
    // MARK: - Logging

    #if LK_SIGNPOSTS
    // Measures the time to acquire the lock and execute side effects
    private let signpostLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "", category: "StateSync")
    // Full (nested) type name
    private let stateTypeName = String(reflecting: State.self)
    #endif

    // MARK: - Types

    public typealias OnDidMutate = @Sendable (_ newState: State, _ oldState: State) -> Void

    // MARK: - Public

    public var onDidMutate: OnDidMutate? {
        get { _lock.sync { _onDidMutate } }
        set { _lock.sync { _onDidMutate = newValue } }
    }

    // MARK: - Private

    private var _state: State
    private let _lock: some Lock = createLock()
    private var _onDidMutate: OnDidMutate?

    public init(_ state: State, onDidMutate: OnDidMutate? = nil) {
        _state = state
        _onDidMutate = onDidMutate
    }

    // mutate sync
    @discardableResult
    public func mutate<Result>(_ block: (inout State) throws -> Result, file: StaticString = #file, line: Int = #line, function: String = #function) rethrows -> Result {
        #if LK_SIGNPOSTS
        let mutateID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: file, signpostID: mutateID, "%s:%d %s %s (lock)", "\(file)", line, function, stateTypeName)
        #endif
        return try _lock.sync {
            #if LK_SIGNPOSTS
            os_signpost(.end, log: signpostLog, name: file, signpostID: mutateID)
            #endif
            let oldState = _state

            #if LK_SIGNPOSTS
            let blockID = OSSignpostID(log: signpostLog)
            os_signpost(.begin, log: signpostLog, name: file, signpostID: blockID, "%s:%d %s %s (block)", "\(file)", line, function, stateTypeName)
            #endif
            let result = try block(&_state)
            #if LK_SIGNPOSTS
            os_signpost(.end, log: signpostLog, name: file, signpostID: blockID)
            #endif
            let newState = _state

            // Always invoke onDidMutate within the lock (sync) since
            // logic following the state mutation may depend on this.
            // Invoke on async queue within _onDidMutate if necessary.
            #if LK_SIGNPOSTS
            let onDidMutateID = OSSignpostID(log: signpostLog)
            os_signpost(.begin, log: signpostLog, name: file, signpostID: onDidMutateID, "%s:%d %s %s (onDidMutate)", "\(file)", line, function, stateTypeName)
            #endif
            _onDidMutate?(newState, oldState)
            #if LK_SIGNPOSTS
            os_signpost(.end, log: signpostLog, name: file, signpostID: onDidMutateID)
            #endif

            return result
        }
    }

    // read sync and return copy
    public func copy(file: StaticString = #file, line: Int = #line, function: String = #function) -> State {
        #if LK_SIGNPOSTS
        let copyID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: file, signpostID: copyID, "%s:%d %s %s (lock)", "\(file)", line, function, stateTypeName)
        #endif
        return _lock.sync {
            #if LK_SIGNPOSTS
            os_signpost(.end, log: signpostLog, name: file, signpostID: copyID)
            #endif
            return _state
        }
    }

    // read with block
    public func read<Result>(_ block: (State) throws -> Result, file: StaticString = #file, line: Int = #line, function: String = #function) rethrows -> Result {
        #if LK_SIGNPOSTS
        let readID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: file, signpostID: readID, "%s:%d %s %s (lock)", "\(file)", line, function, stateTypeName)
        #endif
        return try _lock.sync {
            #if LK_SIGNPOSTS
            os_signpost(.end, log: signpostLog, name: file, signpostID: readID)

            let blockID = OSSignpostID(log: signpostLog)
            os_signpost(.begin, log: signpostLog, name: file, signpostID: blockID, "%s:%d %s %s (block)", "\(file)", line, function, stateTypeName)
            #endif
            let result = try block(_state)
            #if LK_SIGNPOSTS
            os_signpost(.end, log: signpostLog, name: file, signpostID: blockID)
            #endif
            return result
        }
    }

    // property read sync
    public subscript<Property>(dynamicMember keyPath: KeyPath<State, Property>) -> Property {
        #if LK_SIGNPOSTS
        let lookupID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: #function, signpostID: lookupID, "%s %s", stateTypeName, "\(keyPath)")
        #endif
        return _lock.sync {
            #if LK_SIGNPOSTS
            os_signpost(.end, log: signpostLog, name: #function, signpostID: lookupID)
            #endif
            return _state[keyPath: keyPath]
        }
    }
}

extension StateSync: CustomStringConvertible {
    public var description: String {
        "StateSync(\(String(describing: copy()))"
    }
}
