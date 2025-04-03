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
import os

#if canImport(Synchronization)
import Synchronization
#endif

public protocol LockType { // ~Copyable {
    func sync<Result>(_ fnc: () throws -> Result) rethrows -> Result
}

func createLock() -> some LockType {
    if #available(iOS 16.0, macOS 13.0, tvOS 16.0, visionOS 1.0, *) {
        return OSAllocatedUnfairLock()
    } else {
        return UnfairLock()
    }
}

// MARK: - Unfair lock

//
// Read http://www.russbishop.net/the-law for more information on why this is necessary
//
final class UnfairLock: LockType {
    private var _lock: UnsafeMutablePointer<os_unfair_lock>

    fileprivate init() {
        _lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        _lock.initialize(to: os_unfair_lock())
    }

    deinit {
        _lock.deinitialize(count: 1)
        _lock.deallocate()
    }

    @inline(__always)
    func sync<Result>(_ fnc: () throws -> Result) rethrows -> Result {
        os_unfair_lock_lock(_lock)
        defer { os_unfair_lock_unlock(_lock) }
        return try fnc()
    }
}

// MARK: - OSAllocatedUnfairLock

@available(iOS 16.0, macOS 13.0, tvOS 16.0, visionOS 1.0, *)
extension OSAllocatedUnfairLock: LockType where State == Void {
    @inline(__always)
    public func sync<Result>(_ fnc: () throws -> Result) rethrows -> Result {
        try withLockUnchecked(fnc)
    }
}

// MARK: - Mutex

// @available(iOS 18.0, macOS 15.0, tvOS 18.0, visionOS 2.0, *)
// extension Mutex: LockType where Value == () {
//    @inlinable
//    public func sync<Result>(_ fnc: () throws -> Result) rethrows -> Result {
//        try withLock { _ in
//            try fnc()
//        }
//    }
// }
