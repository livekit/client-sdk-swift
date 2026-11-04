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

@testable import LiveKit
import Testing

#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// ``DataTrackStream/firstFrame(within:pushing:)`` retries in a task nothing awaits, so a push
/// that throws there would otherwise stop the retries silently and leave the read to time out —
/// reporting "no frame in 15s" for what is really a full send queue or an ended publication.
@Suite(.serialized, .tags(.e2e, .dataTrack), TestLimits.e2e)
struct DataTrackRetryPushTests {
    private struct PushRefused: Error {}

    @Test
    func aFailedRetryPushSurfacesRatherThanTimingOut() async throws {
        try await TestEnvironment.withPublishedDataTrack(named: "retry-push") { fixture in
            let stream = try await fixture.remoteTrack.subscribe()
            let attempts = StateSync(0)

            // The first push sends nothing, so the read has to wait and the retry runs; the
            // retry then fails the way a full send queue would.
            await #expect(throws: PushRefused.self) {
                _ = try await stream.firstFrame(within: 5) {
                    let attempt = attempts.mutate { $0 += 1; return $0 }
                    if attempt > 1 { throw PushRefused() }
                }
            }
            #expect(attempts.read { $0 } > 1, "the retry never ran, so nothing was proven")
        }
    }
}
