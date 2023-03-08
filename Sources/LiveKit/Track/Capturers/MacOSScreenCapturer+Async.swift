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
import WebRTC
import Promises

#if os(macOS)
public extension MacOSScreenCapturer {

    static func sources(for type: MacOSScreenShareSourceType,
                        includeCurrentApplication: Bool = false,
                        preferredMethod: MacOSScreenCapturePreferredMethod = .auto) async throws -> [MacOSScreenCaptureSource] {

        try await withCheckedThrowingContinuation { continuation in

            sources(for: type,
                    includeCurrentApplication: includeCurrentApplication,
                    preferredMethod: preferredMethod).then(on: queue) { result in
                        continuation.resume(returning: result)
                    }.catch(on: queue) { error in
                        continuation.resume(throwing: error)
                    }
        }
    }
}
#endif
