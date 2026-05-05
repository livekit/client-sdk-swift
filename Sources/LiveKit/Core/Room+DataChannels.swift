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

public extension Room {
    /// Waits until the connect-time data channels have opened.
    ///
    /// ``connect(url:token:connectOptions:roomOptions:)`` returns once the
    /// primary peer connection reaches DTLS completion. Data channels share
    /// the same SCTP transport and typically open within a few milliseconds
    /// after, but the open event is observed asynchronously. Await this
    /// method when full handshake completion (readiness to send and receive
    /// data) must be observed before proceeding.
    ///
    /// Records a `dc_open` event on ``connectSpan`` when the data channels open.
    ///
    /// - Parameters:
    ///   - timeout: The timeout for the operation.
    /// - Throws: `LiveKitError` if data channels do not open within the timeout.
    @discardableResult
    func waitUntilDataChannelsOpen(timeout: TimeInterval = .defaultPublisherDataChannelOpen) async throws -> Self {
        guard let pair = _state.transport?.connectDataChannelPair(
            publisher: publisherDataChannel,
            subscriber: subscriberDataChannel
        ) else {
            return self
        }
        try await pair.openCompleter.wait(timeout: timeout)
        connectSpan?.record("dc_open")
        return self
    }
}
