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
/// `CaptureService.start/stop`, OpenTelemetry's `Instrumentation.enable/disable` — and, per the
/// design doc, a platform-side convention: an instrument is Swift that calls into the core;
/// nothing long-running crosses the FFI. Lifecycle runs on the ``Telemetry`` actor; the owner's
/// scope decides when: ``Telemetry`` starts and stops the process-level instruments
/// (``DeviceTelemetry``, ``LoggingTelemetry``), ``Room`` its own (``RTCTelemetry``).
@Telemetry
protocol TelemetryInstrument: AnyObject {
    /// Begin observing and pushing.
    func start()
    /// Stop observing. Called once, when the owner's scope ends; settles what is open.
    func stop()
}
