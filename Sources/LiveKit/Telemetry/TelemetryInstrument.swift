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

/// One source of telemetry: something that observes the platform and pushes into the pipeline.
///
/// The shape every client SDK converges on — Sentry's `Integration.install/uninstall`, Embrace's
/// `CaptureService.start/stop`, OpenTelemetry's `Instrumentation.enable/disable` (JS) and
/// `AndroidInstrumentation.install` — and, per the design doc, a platform-side convention: an
/// instrument is idiomatic Swift that calls into the core; nothing long-running crosses the FFI,
/// so instruments never have to be reachable from Rust threads (the uniffi-dart callback
/// constraint) and the core stays a pipeline, not a lifecycle manager.
///
/// Scope is the owner's: ``TelemetryHub`` starts and stops the process-level instruments,
/// ``Room`` its own. Each instrument reads on its own — ``DeviceTelemetry`` (device state),
/// ``RoomTelemetry`` (session identity, spans, events), ``RTCTelemetry`` (track statistics).
protocol TelemetryInstrument: AnyObject, Sendable {
    /// Begin observing and pushing.
    func start()
    /// Stop observing. Called once, when the owner's scope ends; settles what is open.
    func stop()
}
