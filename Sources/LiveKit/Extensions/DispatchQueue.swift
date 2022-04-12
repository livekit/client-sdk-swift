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

internal extension DispatchQueue {

    static let sdk = DispatchQueue(label: "LiveKitSDK", qos: .userInitiated)
    static let webRTC = DispatchQueue(label: "LiveKitSDK.webRTC", qos: .default)
    static let capture = DispatchQueue(label: "LiveKitSDK.capture", qos: .default)

    // execute work on the main thread if not already on the main thread
    static func mainSafeSync<T>(execute work: () throws -> T) rethrows -> T {
        guard !Thread.current.isMainThread else { return try work() }
        return try Self.main.sync(execute: work)
    }

    // if already on main, immediately execute block.
    // if not on main, schedule async.
    static func mainSafeAsync(execute work: @escaping () -> Void) {
        guard !Thread.current.isMainThread else { return work() }
        return Self.main.async(execute: work)
    }
}
