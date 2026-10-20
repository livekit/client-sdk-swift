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
import LiveKit

/// An SDK logger that stamps every line with the same monotonic clock the benchmark milestones
/// are measured on, so a log line and a measurement can be placed on one timeline.
///
/// ``PrintLogger`` carries no timestamp, which makes it useless for asking *when* within an
/// iteration something happened — the question any tail investigation starts from.
struct TimelineLogger: Logger {
    private let minLevel: LogLevel

    init(minLevel: LogLevel = .debug) {
        self.minLevel = minLevel
    }

    // swiftlint:disable:next function_parameter_count
    func log(
        _ message: @autoclosure () -> CustomStringConvertible,
        _ level: LogLevel,
        source _: @autoclosure () -> String?,
        file _: StaticString,
        type: Any.Type,
        function: StaticString,
        line _: UInt,
        metaData _: ScopedMetadataContainer,
    ) {
        guard level >= minLevel else { return }
        print("[t=\(Int(nowMs()))] [\(level)] \(type).\(function) \(message())")
    }
}

/// Emits a per-iteration timeline on the same clock, so the SDK's own lines can be read against
/// the milestones the benchmark measured.
///
/// Printed only under `LK_BENCH_SDK_LOG=1`: these lines are an investigation aid, and a normal
/// run should stay readable.
enum Timeline {
    /// Per-iteration milestone lines: one `print` per iteration, cheap enough to leave on for a
    /// measured run. This is what raw samples are read from, so percentiles can be computed over
    /// the pooled set instead of by averaging each run's percentiles — which is not a percentile
    /// of anything once the runs differ.
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["LK_BENCH_TIMELINE"] == "1" }

    /// Full SDK logging: a synchronous `print` per log line, on the paths being timed. Diagnosis
    /// only — never combine it with a run whose numbers will be reported.
    static var isSDKLoggingEnabled: Bool { ProcessInfo.processInfo.environment["LK_BENCH_SDK_LOG"] == "1" }

    static func mark(_ label: String, _ milestones: [(String, Double)]) {
        guard isEnabled || isSDKLoggingEnabled, let origin = milestones.first?.1 else { return }
        let offsets = milestones.map { "\($0.0)=\(Int($0.1 - origin))" }.joined(separator: " ")
        print("[t=\(Int(origin))] [TIMELINE] \(label) \(offsets)")
    }
}
