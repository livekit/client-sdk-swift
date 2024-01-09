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

/// Default timeout `TimeInterval`s used throughout the SDK.
public extension TimeInterval {
    static let defaultReconnectAttemptDelay: Self = 2
    // the following 3 timeouts are used for a typical connect sequence
    static let defaultSocketConnect: Self = 10
    // used for validation mode
    static let defaultHTTPConnect: Self = 5
}

public extension DispatchTimeInterval {
    static let defaultCaptureStart: Self = .seconds(5)
    static let defaultConnectivity: Self = .seconds(10)
    static let defaultPublish: Self = .seconds(10)
    // the following 3 timeouts are used for a typical connect sequence
    static let defaultJoinResponse: Self = .seconds(7)
    static let defaultTransportState: Self = .seconds(10)
    // used for validation mode
    static let defaultPublisherDataChannelOpen: Self = .seconds(7)

    static let sid: Self = .seconds(7 + 5) // Join response + 5
}
