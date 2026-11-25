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

/// Counts only known media diagnostics. Healthy frames never enter this helper.
final class MediaLogSummary: Sendable {
    enum Event: String, CaseIterable, Sendable {
        case processingBusy = "video.processing_busy"
        case processorDrop = "video.processor_drop"
        case bufferNotReady = "video.buffer_not_ready"
        case invalidSample = "video.invalid_sample"
        case unsupportedFormat = "video.unsupported_format"
        case unsafeDimensions = "video.unsafe_dimensions"
        case missingPixelBuffer = "video.missing_pixel_buffer"
        case conversionFailed = "video.conversion_failed"
        case renderUnsafeDimensions = "video.render_unsafe_dimensions"
        case converterUnavailable = "audio.converter_unavailable"
        case engineMissing = "audio.engine_missing"
        case recordConversionFailed = "audio.record_conversion_failed"
        case engineUnavailable = "audio.engine_unavailable"

        var level: LogLevel {
            switch self {
            case .processingBusy, .processorDrop, .bufferNotReady, .engineUnavailable: .debug
            case .conversionFailed, .recordConversionFailed: .error
            default: .warning
            }
        }
    }

    struct Entry: Sendable {
        let event: Event
        let file: StaticString
        let function: StaticString
        let line: UInt
        let started: UInt64
        var repeats: UInt64 = 0
        var saturated = false

        mutating func increment() {
            if repeats == .max { saturated = true } else { repeats += 1 }
        }

        func body(now: UInt64, final: Bool) -> String {
            "event=\(event.rawValue) repeated_count=\(repeats) window_ms=\((now &- started) / 1_000_000) final=\(final) count_saturated=\(saturated)"
        }
    }

    // Reference storage avoids StateSync copying the counter dictionary on every repeat.
    // Access stays entirely within state.read; the mutable storage never escapes its lock.
    private final class State {
        var entries: [Event: Entry] = [:]
        var timer: DispatchSourceTimer?
        var stopped = false
        var generation: UInt64 = 0
    }

    typealias Emit = @Sendable (Entry, String) -> Void
    private let state = StateSync(State())
    private let interval: TimeInterval
    private let now: @Sendable () -> UInt64
    private let emit: Emit
    private let automatic: Bool

    /// Five seconds bounds diagnostic volume without storing frame data or interpolated messages.
    init(type: Any.Type, interval: TimeInterval = 5,
         automatic: Bool = true,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         emit: Emit? = nil)
    {
        self.interval = interval
        self.automatic = automatic
        self.now = now
        self.emit = emit ?? { entry, body in
            SDKLog.log(body, entry.event.level, type: type, file: entry.file, function: entry.function, line: entry.line)
        }
    }

    deinit { finish() }

    /// Formats the first occurrence only. Repeat state has fixed keys and no message payloads.
    func record(_ event: Event, _ message: @autoclosure () -> String,
                file: StaticString = #fileID, function: StaticString = #function, line: UInt = #line)
    {
        let first: Entry? = state.read { value in
            guard !value.stopped else { return nil }
            if value.entries[event] != nil {
                value.entries[event]?.increment()
                return nil
            }
            let entry = Entry(event: event, file: file, function: function, line: line, started: now())
            value.entries[event] = entry
            if automatic, value.timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + interval)
                let generation = value.generation
                timer.setEventHandler { [weak self] in self?.flush(generation: generation) }
                value.timer = timer
                timer.resume()
            }
            return entry
        }
        if let first { emit(first, message()) }
    }

    /// Starts a new media lifetime after an explicit stop.
    func resume() { state.read { $0.stopped = false } }

    /// Drains a partial window at graceful stop; core consent still gates every telemetry record.
    func finish() { flush(final: true) }

    /// Driven by one owned timer, or explicitly by deterministic tests. Never logs under the lock.
    func flush(final: Bool = false, generation: UInt64? = nil) {
        let entries: [Event: Entry] = state.read { value in
            guard generation == nil || generation == value.generation else { return [:] }
            value.generation &+= 1
            if final { value.stopped = true }
            value.timer?.cancel()
            value.timer = nil
            let entries = value.entries
            value.entries.removeAll(keepingCapacity: true)
            return entries
        }
        let timestamp = now()
        for entry in entries.values where entry.repeats > 0 {
            emit(entry, entry.body(now: timestamp, final: final))
        }
    }
}
