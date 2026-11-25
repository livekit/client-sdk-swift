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
/// `seed` (endpoint unreachable) leaves batches in this process name's cache for `beforeRoom` and
/// `roomDuringOptOut`; `concurrentDisable` needs neither; `duringRequest` and `duringSubmit`
/// connect to `livekit-server --dev`.
///
/// A case that fails must still end: every hook that holds a thread lets go after ``hold``, each
/// case clears its hooks on the way out, and the suite's time limit ends a case that stalls.
@Suite(.serialized, .timeLimit(.minutes(1))) struct TelemetryOptOutProcessTests {
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

    /// Entries in the cache directory this process name uses (an earlier launch's, before a
    /// pipeline); `nil` when the directory does not exist. Any other failure to list it throws,
    /// so an unreadable cache never passes for an empty one.
    private static func cachedFiles() throws -> Int? {
        let directory = try #require(Telemetry.storageDirectory)
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path).count
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// The longest a test hook holds the thread it runs on, so a failed case cannot hang it.
    private static let hold = 30.0

    /// A hook that signals `reached` and then holds its thread until `release`, at most ``hold``.
    private static func holding(_ reached: DispatchSemaphore, until release: DispatchSemaphore) -> @Sendable () -> Void {
        {
            reached.signal()
            _ = release.wait(timeout: .now() + hold)
        }
    }

    /// Whether `semaphore` is signalled within `seconds`, waited for off the cooperative pool.
    /// Consumes the signal.
    private static func signalled(_ semaphore: DispatchSemaphore, within seconds: Double = 5) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + seconds) == .success)
            }
        }
    }

    /// Runs `work` off this task. The group empties once `work` returned; see ``finished(_:within:)``.
    private static func run(_ work: @escaping @Sendable () -> Void) -> DispatchGroup {
        let running = DispatchGroup()
        running.enter()
        DispatchQueue.global().async {
            work()
            running.leave()
        }
        return running
    }

    /// Whether the work behind `running` returned within `seconds`. Asking again gives the same answer.
    private static func finished(_ running: DispatchGroup, within seconds: Double = 5) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: running.wait(timeout: .now() + seconds) == .success)
            }
        }
    }

    /// Calls the opt-out off this task and reports whether it returned within 5 s.
    private static func disableReturns() async -> Bool {
        await finished(run { LiveKitSDK.disableTelemetry() })
    }

    /// Lets go of every thread a hook may hold and removes the hooks.
    private static func letGo(_ held: DispatchSemaphore...) {
        Telemetry.beforeInstall.mutate { $0 = nil }
        Telemetry.beforeCleanUp.mutate { $0 = nil }
        Telemetry.afterCleanUpScheduled.mutate { $0 = nil }
        for semaphore in held {
            semaphore.signal()
        }
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
        #expect(try #require(try Self.cachedFiles()) > 0)
    }

    /// Before any Room: the call returns while the clean-up is held, nothing is collected, and
    /// once released the clean-up deletes the earlier launch's cache.
    @Test(.enabled(if: selected == "beforeRoom"))
    func beforeRoom() async throws {
        let seeded = try #require(try Self.cachedFiles(), "run the seed case first")
        #expect(seeded > 0, "run the seed case first")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        Telemetry.beforeCleanUp.mutate { $0 = Self.holding(entered, until: release) }
        defer { Self.letGo(release) }

        #expect(await Self.disableReturns())
        #expect(await Self.signalled(entered))
        #expect(try Self.cachedFiles() == seeded) // held: nothing deleted yet

        #expect(telemetryIsDisabled())
        #expect(Telemetry.scope() == nil)
        let room = Room()
        #expect(room.telemetryScope == nil)
        #expect(room.rtcTelemetry == nil)

        release.signal()
        await Telemetry.cleanUpFinished()
        #expect(try Self.cachedFiles() ?? 0 == 0) // deleted with or without its directory
    }

    /// The first Room racing the opt-out. The Room's install is held right after its opt-out
    /// check, an opt-out is started and given a second to overtake it, and the install is let go.
    ///
    /// Whatever order the SDK then picks, the install must reach a core that is not opted out:
    /// an opted-out core refuses the configure and makes it, and the Room, wait for its purge.
    /// The released core gives its host no way to hold that purge, so the case checks this
    /// invariant where the wait would start, not the wait itself. Both calls must return, a
    /// later Room is created while the clean-up is held, and once let go the clean-up deletes
    /// the earlier launch's cache.
    @Test(.enabled(if: selected == "roomDuringOptOut"))
    func roomDuringOptOut() async throws {
        #expect(try #require(try Self.cachedFiles(), "run the seed case first") > 0, "run the seed case first")
        let installing = DispatchSemaphore(value: 0), install = DispatchSemaphore(value: 0)
        let optedOutAtInstall = StateSync<Bool?>(nil)
        Telemetry.beforeInstall.mutate {
            $0 = {
                Self.holding(installing, until: install)()
                optedOutAtInstall.mutate { $0 = telemetryIsDisabled() }
            }
        }
        let cleaning = DispatchSemaphore(value: 0), clean = DispatchSemaphore(value: 0)
        Telemetry.beforeCleanUp.mutate { $0 = Self.holding(cleaning, until: clean) }
        defer { Self.letGo(install, clean) }

        let first = Self.run { _ = Room() }
        #expect(await Self.signalled(installing))
        let entering = DispatchSemaphore(value: 0)
        let optOut = Self.run {
            entering.signal()
            LiveKitSDK.disableTelemetry()
        }
        #expect(await Self.signalled(entering))
        let overtook = await Self.finished(optOut, within: 1) // its chance; not an expectation
        install.signal()

        #expect(await Self.finished(first))
        #expect(await Self.finished(optOut))
        #expect(optedOutAtInstall.copy() == false, "the opt-out returned under the held install: \(overtook)")
        #expect(await Self.signalled(cleaning))
        #expect(telemetryIsDisabled())
        #expect(await Self.finished(Self.run { _ = Room() }))
        #expect(Telemetry.scope() == nil)

        clean.signal()
        await Telemetry.cleanUpFinished()
        #expect(try Self.cachedFiles() ?? 0 == 0) // deleted with or without its directory
    }

    /// Overlapping opt-outs: the first caller is held right after it scheduled the clean-up, a
    /// second caller returns at once, and awaiting the clean-up from there still waits for it.
    /// Eight more concurrent opt-outs schedule nothing: the clean-up runs exactly once.
    @Test(.enabled(if: selected == "concurrentDisable"))
    func concurrentDisable() async {
        let runs = StateSync(0)
        Telemetry.beforeCleanUp.mutate { $0 = { runs.mutate { $0 += 1 } } }
        let scheduled = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        Telemetry.afterCleanUpScheduled.mutate { $0 = Self.holding(scheduled, until: release) }
        defer { Self.letGo(release) }
        let first = Self.run { LiveKitSDK.disableTelemetry() }
        #expect(await Self.signalled(scheduled))

        #expect(await Self.disableReturns())
        await Telemetry.cleanUpFinished()
        #expect(runs.copy() == 1)

        release.signal()
        #expect(await Self.finished(first))
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
            defer { pause.resume() } // the held reading ends on every way out
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
