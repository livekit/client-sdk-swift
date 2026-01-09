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

/// A protocol that defines a message receiver.
///
/// A message receiver is responsible for creating a stream of messages from the agent.
/// It is used to receive messages from the agent and update the message feed.
public protocol MessageReceiver: Sendable {
    func messages() async throws -> AsyncStream<ReceivedMessage>
}
