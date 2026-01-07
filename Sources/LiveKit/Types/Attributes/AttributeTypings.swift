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

// Quicktype cannot generate both at the same time
extension AgentAttributes: Hashable {}
extension AgentAttributes: Equatable {}

// Bool as String encoding
extension TranscriptionAttributes {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lkSegmentID = try container.decodeIfPresent(String.self, forKey: .lkSegmentID)
        lkTranscribedTrackID = try container.decodeIfPresent(String.self, forKey: .lkTranscribedTrackID)

        // Decode as Bool first, fallback to String
        if let boolValue = try? container.decodeIfPresent(Bool.self, forKey: .lkTranscriptionFinal) {
            lkTranscriptionFinal = boolValue
        } else if let stringValue = try? container.decodeIfPresent(String.self, forKey: .lkTranscriptionFinal) {
            lkTranscriptionFinal = (stringValue as NSString).boolValue
        } else {
            lkTranscriptionFinal = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(lkSegmentID, forKey: .lkSegmentID)
        try container.encodeIfPresent(lkTranscribedTrackID, forKey: .lkTranscribedTrackID)

        // Always encode Bool as a string if it exists
        if let boolValue = lkTranscriptionFinal {
            try container.encode(boolValue ? "true" : "false", forKey: .lkTranscriptionFinal)
        }
    }
}

// MARK: - AgentAttributes

struct AgentAttributes: Codable, Sendable {
    let lkAgentInputs: [AgentInput]?
    let lkAgentOutputs: [AgentOutput]?
    let lkAgentState: AgentState?
    let lkPublishOnBehalf: String?

    enum CodingKeys: String, CodingKey {
        case lkAgentInputs = "lk.agent.inputs"
        case lkAgentOutputs = "lk.agent.outputs"
        case lkAgentState = "lk.agent.state"
        case lkPublishOnBehalf = "lk.publish_on_behalf"
    }
}

enum AgentInput: String, Codable, Sendable {
    case audio
    case text
    case video
}

enum AgentOutput: String, Codable, Sendable {
    case audio
    case transcription
}

public enum AgentState: String, Codable, Sendable {
    case idle
    case initializing
    case listening
    case speaking
    case thinking
}

// MARK: - TranscriptionAttributes

/// Schema for transcription-related attributes
struct TranscriptionAttributes: Codable, Sendable {
    /// The segment id of the transcription
    let lkSegmentID: String?
    /// The associated track id of the transcription
    let lkTranscribedTrackID: String?
    /// Whether the transcription is final
    let lkTranscriptionFinal: Bool?

    enum CodingKeys: String, CodingKey {
        case lkSegmentID = "lk.segment_id"
        case lkTranscribedTrackID = "lk.transcribed_track_id"
        case lkTranscriptionFinal = "lk.transcription_final"
    }
}
