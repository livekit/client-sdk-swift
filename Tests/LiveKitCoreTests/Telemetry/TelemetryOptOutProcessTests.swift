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
import LiveKitFFI
import Testing
#if canImport(LiveKitTestSupport)
import LiveKitTestSupport
#endif

/// `LiveKitSDK.disableTelemetry()` through the released core, one case per process: the opt-out
/// lasts for the rest of a process, so a case that ran after it in the same process would pass
/// vacuously. Each case runs only when `LK_TELEMETRY_OPT_OUT_CASE` names it, with
/// `LK_TELEMETRY_ENDPOINT` pointing the pipeline at a local recorder that answers `GET
/// /count?marker=<text>` with how many received batches contain `<text>`:
///
///     LK_TELEMETRY_OPT_OUT_CASE=capture LK_TELEMETRY_ENDPOINT=http://127.0.0.1:<port> \
///         swift test --filter TelemetryOptOutProcessTests
///
/// `seed` (endpoint unreachable) leaves batches in this process name's cache for `beforeRoom`;
/// `concurrentDisable` needs neither; `duringRequest` and `duringSubmit` connect to `livekit-server --dev`.
@Suite(.serialized) struct TelemetryOptOutProcessTests {
    private static let selected = ProcessInfo.processInfo.environment["LK_TELEMETRY_OPT_OUT_CASE"]
    private static let recorder = ProcessInfo.processInfo.environment["LK_TELEMETRY_ENDPOINT"].flatMap(URL.init(string:))

    /// Batches the recorder received that contain `marker`, after flushing what is queued.
    private static func recorded(_ marker: String) async throws -> Int {
        await telemetryFlush()
        let recorder = try #require(recorder)
        let url = try #require(URL(string: "\(recorder.absoluteString)/count?marker=\(marker)"))
        let (data, _) = try await URLSession.shared.data(from: url)
        return try #require(String(bytes: data, encoding: .utf8).flatMap { Int($0) })
    }

    private static func marker(_ name: String) -> String {
        "optout-\(name)-\(UUID().uuidString.prefix(8))"
    }

    /// Batch files in the cache this process name uses (an earlier launch's, before a pipeline).
    private static func cachedFiles() -> Int {
        guard let directory = Telemetry.storageDirectory,
              let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        return files.allObjects.count
    }

    /// Whether `semaphore` is signalled within 5 s, waited for off the cooperative pool.
    private static func signalled(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    /// Calls the opt-out off this task and reports whether it returned within 5 s.
    private static func disableReturns() async -> Bool {
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            LiveKitSDK.disableTelemetry()
            returned.signal()
        }
        return await signalled(returned)
    }

    private static func assertRevoked(_ oldScope: TelemetryScope) async throws {
        #expect(telemetryIsDisabled())
        #expect(Telemetry.scope() == nil)
        let room = Room()
        #expect(room.telemetryScope == nil)
        #expect(room.rtcTelemetry == nil)
        let late = marker("late")
        oldScope.emitCustom(name: late, attributes: [:])
        #expect(try await recorded(late) == 0)
    }

    /// Positive control: without the opt-out, a Room's record reaches the recorder.
    @Test(.enabled(if: selected == "capture"))
    func capture() async throws {
        let room = Room()
        let scope = try #require(room.telemetryScope)
        let marker = Self.marker("capture")
        scope.emitCustom(name: marker, attributes: [:])
        #expect(try await Self.recorded(marker) >= 1)
    }

    /// An unreachable collector: the batch stays cached for the next process.
    @Test(.enabled(if: selected == "seed"))
    func seed() async throws {
        let room = Room()
        try #require(room.telemetryScope).emitCustom(name: Self.marker("seed"), attributes: [:])
        await telemetryFlush()
        #expect(Self.cachedFiles() > 0)
    }

    /// Before any Room: the call returns while the clean-up is held, nothing is collected, and
    /// once released the clean-up deletes the earlier launch's cache.
    @Test(.enabled(if: selected == "beforeRoom"))
    func beforeRoom() async {
        let seeded = Self.cachedFiles()
        #expect(seeded > 0, "run the seed case first")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        Telemetry.beforeCleanUp.mutate { $0 = { entered.signal(); release.wait() } }

        #expect(await Self.disableReturns())
        #expect(await Self.signalled(entered))
        #expect(Self.cachedFiles() == seeded) // held: nothing deleted yet

        #expect(telemetryIsDisabled())
        #expect(Telemetry.scope() == nil)
        let room = Room()
        #expect(room.telemetryScope == nil)
        #expect(room.rtcTelemetry == nil)

        release.signal()
        await Telemetry.cleanUpFinished()
        #expect(Self.cachedFiles() == 0)
    }

    /// Overlapping opt-outs: the first caller is held right after it scheduled the clean-up, a
    /// second caller returns at once, and awaiting the clean-up from there still waits for it.
    /// Eight more concurrent opt-outs schedule nothing: the clean-up runs exactly once.
    @Test(.enabled(if: selected == "concurrentDisable"))
    func concurrentDisable() async {
        let runs = StateSync(0)
        Telemetry.beforeCleanUp.mutate { $0 = { runs.mutate { $0 += 1 } } }
        let scheduled = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        Telemetry.afterCleanUpScheduled.mutate { $0 = { scheduled.signal(); release.wait() } }
        let firstReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            LiveKitSDK.disableTelemetry()
            firstReturned.signal()
        }
        #expect(await Self.signalled(scheduled))

        #expect(await Self.disableReturns())
        await Telemetry.cleanUpFinished()
        #expect(runs.copy() == 1)

        release.signal()
        #expect(await Self.signalled(firstReturned))
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { await Self.disableReturns() }
            }
            for await returned in group {
                #expect(returned)
            }
        }
        await Telemetry.cleanUpFinished()
        #expect(runs.copy() == 1)
        #expect(telemetryIsDisabled())
    }

    @Test(.enabled(if: selected == "duringRequest"))
    func duringRequest() async throws {
        try await optOut(during: .request, expecting: (answered: 0, submitted: 0))
    }

    @Test(.enabled(if: selected == "duringSubmit"))
    func duringSubmit() async throws {
        try await optOut(during: .submit, expecting: (answered: 1, submitted: 0))
    }

    /// A connected Room reads and submits stats; the opt-out lands while the next reading waits
    /// at `step`; that reading then submits nothing, the Room stops polling, its scope and any
    /// new scope capture nothing, and the Room and its instrument are released afterwards.
    private func optOut(during step: Telemetry.GatedStep, expecting: (answered: Int, submitted: Int)) async throws {
        let room = WeakReference<Room>(), rtc = WeakReference<RTCTelemetry>()
        try await TestEnvironment.withRoom(RoomTestingOptions(isE2eeEnabled: false)) { connected in
            room.value = connected
            rtc.value = connected.rtcTelemetry
            let scope = try #require(connected.telemetryScope)
            let captured = Self.marker("captured")
            scope.emitCustom(name: captured, attributes: [:])
            #expect(try await Self.recorded(captured) >= 1)
            let first = await connected.recordPeerStats(into: scope)
            #expect(first.answered >= 1 && first.submitted == first.answered)

            let pause = Pause(at: step)
            let reading = Task { await Telemetry.$beforeGate.withValue(pause.hook) { await connected.recordPeerStats(into: scope) } }
            await pause.reached()
            #expect(await Self.disableReturns())
            pause.resume()
            let held = await reading.value
            #expect(held.answered == expecting.answered && held.submitted == expecting.submitted)
            #expect(connected.rtcTelemetry?.isPolling == false)
            try await Self.assertRevoked(scope)
        }
        await Telemetry.cleanUpFinished()
        try await poll(timeout: 10, for: "the Room was released") { room.value == nil }
        try await poll(timeout: 10, for: "its RTC instrument was released") { rtc.value == nil }
    }
}
