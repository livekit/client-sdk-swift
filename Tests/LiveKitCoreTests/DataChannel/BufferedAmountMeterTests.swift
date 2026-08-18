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

/// Arithmetic of the buffered-amount mirror. Its behaviour in context — gating writes, restarting on
/// a channel swap — is pinned by ``DataChannelDrainTests``.
@Suite(.tags(.dataChannel))
struct BufferedAmountMeterTests {
    private static let mark: UInt64 = 1024

    private func makeMeter() -> BufferedAmountMeter {
        BufferedAmountMeter(lowWaterMark: Self.mark)
    }

    @Test func startsWithHeadroom() {
        #expect(makeMeter().hasHeadroom)
    }

    @Test func headroomHoldsUpToAndIncludingTheMark() {
        var meter = makeMeter()
        meter.willSend(Int(Self.mark))
        #expect(meter.hasHeadroom, "the mark itself is still sendable")

        meter.willSend(1)
        #expect(!meter.hasHeadroom)
    }

    @Test func drainedBytesRestoreHeadroom() {
        var meter = makeMeter()
        meter.willSend(Int(Self.mark) + 512)
        #expect(!meter.hasHeadroom)

        meter.didDrain(256)
        #expect(!meter.hasHeadroom, "still above the mark")

        meter.didDrain(256)
        #expect(meter.hasHeadroom)
    }

    /// A report larger than the mirror cannot be honored; clamping to zero keeps the gate open
    /// rather than wedging the drain on an underflowed count.
    @Test func overReportSelfHealsToZeroAndReportsDrift() {
        var meter = makeMeter()
        meter.willSend(64)
        // Called outside `#expect`: the macro captures the value immutably, so a mutating member
        // cannot be invoked inside it.
        let honored = meter.didDrain(4096)
        #expect(honored == false, "drift is reported so the caller can log it")
        #expect(meter.pending == 0)

        // Zero, not a wrapped `UInt64`: another mark's worth must still fit.
        meter.willSend(Int(Self.mark))
        #expect(meter.hasHeadroom)
        meter.willSend(1)
        #expect(!meter.hasHeadroom)
    }

    /// Expected right after a reset, when the closing channel flushes bytes the mirror has already
    /// forgotten — not drift, and not worth an error log.
    @Test func reportAgainstAnEmptyMirrorIsNotDrift() {
        var meter = makeMeter()
        let honored = meter.didDrain(4096)
        #expect(honored)
        #expect(meter.pending == 0)
    }

    @Test func resetClearsTheMirror() {
        var meter = makeMeter()
        meter.willSend(Int(Self.mark) * 4)
        #expect(!meter.hasHeadroom)

        meter.reset()
        #expect(meter.hasHeadroom)
    }

    /// Retuning changes how much counts as too much, not what is outstanding.
    @Test func retuningMovesTheGateWithoutTouchingTheMirror() {
        var meter = makeMeter()
        meter.willSend(Int(Self.mark) + 1)
        #expect(!meter.hasHeadroom)

        meter.setLowWaterMark(Self.mark * 4)
        #expect(meter.hasHeadroom)
        #expect(meter.pending == UInt64(Self.mark) + 1)
    }
}
