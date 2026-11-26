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

internal import LiveKitFFI
import Foundation

// Native records feed the existing public types directly.
extension NativeParticipantState {
    var lkType: ParticipantState {
        switch self {
        case .joining: .joining
        case .joined: .joined
        case .active: .active
        case .disconnected: .disconnected
        @unknown default: .unknown
        }
    }
}

extension NativeParticipantKind {
    var lkType: Participant.Kind {
        switch self {
        case .standard: .standard
        case .ingress: .ingress
        case .egress: .egress
        case .sip: .sip
        case .agent: .agent
        default: .unknown
        }
    }
}

extension NativeTrackSource {
    var lkType: Track.Source {
        switch self {
        case .camera: .camera
        case .microphone: .microphone
        case .screenshare: .screenShareVideo
        case .screenshareAudio: .screenShareAudio
        default: .unknown
        }
    }
}

extension NativeEncryptionType {
    var lkType: EncryptionType {
        switch self {
        case .none: .none
        case .gcm: .gcm
        default: .custom
        }
    }
}

extension NativeParticipantPermission {
    var lkType: ParticipantPermissions {
        ParticipantPermissions(canSubscribe: canSubscribe,
                               canPublish: canPublish,
                               canPublishData: canPublishData,
                               canPublishSources: Set(canPublishSources.map(\.lkType)),
                               hidden: hidden,
                               canUpdateMetadata: canUpdateMetadata,
                               canSubscribeMetrics: canSubscribeMetrics,
                               canManageAgentSession: canManageAgentSession)
    }
}

extension NativeDisconnectReason {
    var lkErrorType: LiveKitErrorType {
        switch self {
        case .clientInitiated: .cancelled
        case .duplicateIdentity: .duplicateIdentity
        case .serverShutdown: .serverShutdown
        case .participantRemoved: .participantRemoved
        case .roomDeleted: .roomDeleted
        case .stateMismatch: .stateMismatch
        case .joinFailure: .joinFailure
        default: .unknown
        }
    }
}
