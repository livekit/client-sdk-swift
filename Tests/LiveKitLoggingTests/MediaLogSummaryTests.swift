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

struct MediaLogSummaryTests {
    private final class Output: Sendable {
        let time = StateSync<UInt64>(0)
        let records = StateSync<[(MediaLogSummary.Entry, String)]>([])

        func make(automatic: Bool = false) -> MediaLogSummary {
            MediaLogSummary(type: Self.self, interval: 0.01, automatic: automatic,
                            now: { [time] in time.copy() },
                            emit: { [records] entry, body in records.mutate { $0.append((entry, body)) } })
        }
    }

    @Test func countsAndLaziness() {
        let output = Output()
        let summary = output.make()
        var formatted = 0
        func message() -> String { formatted += 1; return "first" }
        for _ in 0 ..< 120 {
            summary.record(.unsafeDimensions, message(), file: "Capture.swift", function: "capture", line: 42)
        }
        #expect(formatted == 1)
        output.time.mutate { $0 = 5_000_000_000 }
        summary.flush()
        summary.flush()
        let records = output.records.copy()
        #expect(records.count == 2)
        #expect(records.last?.0.repeats == 119)
        #expect(records.last?.1 == "media diagnostic repeated: event=video.unsafe_dimensions repeated_count=119 window_ms=5000 final=false count_saturated=false")
        #expect(records.last?.0.file.description == "Capture.swift")
        #expect(records.last?.0.line == 42)
    }

    @Test func ownersKeysAndStop() {
        let output = Output()
        let first = output.make()
        let second = output.make()
        for _ in 0 ..< 3 {
            first.record(.unsupportedFormat, "format")
            first.record(.processorDrop, "drop")
            second.record(.unsupportedFormat, "other")
        }
        first.finish()
        first.record(.unsupportedFormat, "ignored")
        second.finish()
        #expect(output.records.copy().count == 6)
        #expect(output.records.copy().suffix(3).allSatisfy { $0.0.repeats == 2 && $0.1.contains("final=true") })
        first.resume()
        first.record(.unsupportedFormat, "new lifetime")
        first.finish()
        #expect(output.records.copy().count == 7)
    }

    @Test func staleTimerCannotDrainNewWindow() {
        let output = Output()
        let summary = output.make()
        summary.record(.unsupportedFormat, "first")
        summary.flush()
        summary.record(.unsupportedFormat, "new")
        summary.record(.unsupportedFormat, "repeat")
        summary.flush(generation: 0)
        #expect(output.records.copy().count == 2)
        summary.finish()
        #expect(output.records.copy().last?.0.repeats == 1)
    }

    @Test func saturation() {
        var entry = MediaLogSummary.Entry(event: .unsafeDimensions, file: "f", function: "g", line: 1, started: 0)
        entry.repeats = .max
        entry.increment()
        #expect(entry.repeats == .max)
        #expect(entry.saturated)
    }

    @Test(arguments: MediaLogSummary.Event.allCases)
    func severity(_ event: MediaLogSummary.Event) {
        switch event {
        case .processingBusy, .processorDrop, .bufferNotReady, .engineUnavailable: #expect(event.level == .debug)
        case .conversionFailed, .recordConversionFailed: #expect(event.level == .error)
        default: #expect(event.level == .warning)
        }
    }

    @Test func concurrentCounts() async {
        let output = Output()
        let summary = output.make()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    for _ in 0 ..< 1000 {
                        summary.record(.conversionFailed, "failure")
                    }
                }
            }
        }
        summary.finish()
        #expect(output.records.copy().count == 2)
        #expect(output.records.copy().last?.0.repeats == 7999)
    }

    @Test(arguments: 0 ..< 100) func quietTimerAndDestruction(_: Int) {
        let queue = DispatchQueue(label: "logging-test.timer")
        let emitted = DispatchSemaphore(value: 0)
        let records = StateSync<[UInt64]>([])
        var summary: MediaLogSummary? = MediaLogSummary(type: Self.self, interval: 0,
                                                        timerQueue: queue, emit: { entry, _ in
                                                            records.mutate { $0.append(entry.repeats) }
                                                            if entry.repeats > 0 { emitted.signal() }
                                                        })
        weak var weakSummary: MediaLogSummary?
        weakSummary = summary
        queue.suspend()
        summary?.record(.unsafeDimensions, "first")
        summary?.record(.unsafeDimensions, "second")
        queue.resume()
        #expect(emitted.wait(timeout: .now() + 2) == .success)
        // Join the callback, including its temporary strong reference, before releasing the owner.
        queue.sync {}
        summary = nil
        #expect(weakSummary == nil)
        #expect(records.copy() == [0, 1])
    }

    @Test(arguments: 0 ..< 100) func pendingTimerDoesNotRetainOwner(_: Int) {
        let queue = DispatchQueue(label: "logging-test.pending")
        queue.suspend()
        defer { queue.resume() }
        let output = Output()
        var summary: MediaLogSummary? = MediaLogSummary(type: Self.self, timerQueue: queue,
                                                        emit: { entry, body in
                                                            output.records.mutate { $0.append((entry, body)) }
                                                        })
        weak var weakSummary: MediaLogSummary?
        weakSummary = summary
        summary?.record(.unsafeDimensions, "first")
        summary?.record(.unsafeDimensions, "second")
        summary = nil
        #expect(weakSummary == nil)
        #expect(output.records.copy().count == 2)
        #expect(output.records.copy().last?.0.repeats == 1)
        #expect(output.records.copy().last?.1.contains("final=true") == true)
    }
}
