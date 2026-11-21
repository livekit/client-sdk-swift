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
@testable import LiveKit
import Testing

/// Runs the Session compatibility checks without accessing real microphone hardware.
@Suite(.serialized, .tags(.e2e), .enabled(if: ProcessInfo.processInfo.environment["LK_SESSION_STAGING_TESTS"] == "1"))
struct SessionStagingValidationTests {
    @Test(.timeLimit(.minutes(5))) @MainActor func sessionCompatibility() async throws {
        try await SessionTestAudioSource.withAudio {
            let checks = SessionStartupTests()
            for singlePC in [true, false] {
                for preConnectAudio in [true, false] {
                    try await checks.joinsBeforeCaptureAndPublishesOnce(singlePC: singlePC, preConnectAudio: preConnectAudio)
                    print("STAGING_CHECK joined-before-capture pc=\(singlePC) buffer=\(preConnectAudio)")
                }
            }
            try await checks.endingDuringPermissionCannotPublishOrDisconnectNextAttempt()
            print("STAGING_CHECK late-permission-and-restart")
            try await checks.endingDuringICEWaitJoinsConnectionTeardown()
            print("STAGING_CHECK cancellation-during-ICE")
            try await checks.captureFailureClosesReservation()
            print("STAGING_CHECK capture-failure")
            try await checks.encryptedSessionFallsBackToNormalPublication()
            print("STAGING_CHECK encryption-fallback")
            try await checks.fullReconnectRepublishesAttachedTrack()
            print("STAGING_CHECK quick-and-full-reconnect")
            try await checks.joinReservationDoesNotEnableMicrophoneRTP()
            print("STAGING_CHECK inactive-reservation")
            try await checks.completedStartupReleasesItsTaskOwner()
            print("STAGING_CHECK task-owner-destruction")
        }
    }
}
