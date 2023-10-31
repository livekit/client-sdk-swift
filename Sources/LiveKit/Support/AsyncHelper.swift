/*
 * Copyright 2023 LiveKit
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

// TODO: Remove helper method when async/await migration completed

// No params
internal func promise<T>(from asyncFunction: @escaping () async throws -> T) -> Promise<T> {
    return Promise<T> { resolve, reject in
        Task {
            do {
                let result = try await asyncFunction()
                resolve(result)
            } catch let error {
                reject(error)
            }
        }
    }
}

// 1 param
internal func promise<T, P1>(from asyncFunction: @escaping (P1) async throws -> T, param1: P1) -> Promise<T> {
    return Promise<T> { resolve, reject in
        Task {
            do {
                let result = try await asyncFunction(param1)
                resolve(result)
            } catch let error {
                reject(error)
            }
        }
    }
}

// 2 params
internal func promise<T, P1, P2>(from asyncFunction: @escaping (P1, P2) async throws -> T, param1: P1, param2: P2) -> Promise<T> {
    return Promise<T> { resolve, reject in
        Task {
            do {
                let result = try await asyncFunction(param1, param2)
                resolve(result)
            } catch let error {
                reject(error)
            }
        }
    }
}

// 3 params
internal func promise<T, P1, P2, P3>(from asyncFunction: @escaping (P1, P2, P3) async throws -> T, param1: P1, param2: P2, param3: P3) -> Promise<T> {
    return Promise<T> { resolve, reject in
        Task {
            do {
                let result = try await asyncFunction(param1, param2, param3)
                resolve(result)
            } catch let error {
                reject(error)
            }
        }
    }
}

// 4 params
internal func promise<T, P1, P2, P3, P4>(from asyncFunction: @escaping (P1, P2, P3, P4) async throws -> T, param1: P1, param2: P2, param3: P3, param4: P4) -> Promise<T> {
    return Promise<T> { resolve, reject in
        Task {
            do {
                let result = try await asyncFunction(param1, param2, param3, param4)
                resolve(result)
            } catch let error {
                reject(error)
            }
        }
    }
}

// 5 params
internal func promise<T, P1, P2, P3, P4, P5>(from asyncFunction: @escaping (P1, P2, P3, P4, P5) async throws -> T, param1: P1, param2: P2, param3: P3, param4: P4, param5: P5) -> Promise<T> {
    return Promise<T> { resolve, reject in
        Task {
            do {
                let result = try await asyncFunction(param1, param2, param3, param4, param5)
                resolve(result)
            } catch let error {
                reject(error)
            }
        }
    }
}

// 6 params
internal func promise<T, P1, P2, P3, P4, P5, P6>(from asyncFunction: @escaping (P1, P2, P3, P4, P5, P6) async throws -> T, param1: P1, param2: P2, param3: P3, param4: P4, param5: P5, param6: P6) -> Promise<T> {
    return Promise<T> { resolve, reject in
        Task {
            do {
                let result = try await asyncFunction(param1, param2, param3, param4, param5, param6)
                resolve(result)
            } catch let error {
                reject(error)
            }
        }
    }
}
