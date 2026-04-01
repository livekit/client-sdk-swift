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

/// A message received from the agent.
public struct ReceivedMessage: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let timestamp: Date
    public let content: Content

    /// Whether this message represents a finalized transcription segment.
    ///
    /// A segment is finalized when its text is complete and will not change further.
    /// Two signals can set this to `true`:
    /// - The `lk.transcription_final` stream attribute is `"true"` (attribute-based).
    /// - The text stream closes, implying the segment is complete (stream-close).
    public let isFinal: Bool

    public enum Content: Equatable, Codable, Sendable {
        case agentTranscript(String)
        case userTranscript(String)
        case userInput(String)
    }

    public init(id: String, timestamp: Date, content: Content, isFinal: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.content = content
        self.isFinal = isFinal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        content = try container.decode(Content.self, forKey: .content)
        isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
    }
}

/// A message sent to the agent.
public struct SentMessage: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let timestamp: Date
    public let content: Content

    public enum Content: Equatable, Codable, Sendable {
        case userInput(String)
    }
}
