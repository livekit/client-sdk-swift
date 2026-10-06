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

internal import LiveKitUniFFI
import AVFoundation
import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// The device instrument: thermal state, low-power mode, memory pressure, network path, battery
/// and app lifecycle as `DeviceState`, audio-session changes as events. Every OS callback yields
/// into one stream that this actor drains in order; the core turns state into `lk.device.*`
/// records and upload holds. Nothing polls.
actor DeviceTelemetry: TelemetryInstrument {
    /// One OS observation.
    enum Change: Sendable {
        /// Thermal state or low-power mode: read fresh from `ProcessInfo`.
        case power
        case app(AppState)
        case memory(MemoryPressure)
        case network(NetworkType, expensive: Bool, constrained: Bool)
        case battery(level: UInt32?, charging: Bool)
        case event(DeviceEvent)
    }

    private static let queue = DispatchQueue(label: "LiveKitSDK.telemetry.device", qos: .utility)
    private static let executor = DispatchQueueExecutor(queue: queue)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self.executor.asUnownedSerialExecutor()
    }

    nonisolated let changes: AsyncStream<Change>.Continuation
    private let stream: AsyncStream<Change>

    private var state = DeviceState(thermal: .unknown, appState: .foreground, memory: .normal, network: .unknown)
    private var loop: AnyTaskCancellable?
    /// Set by `stop()` itself, so nothing registers once stopped, whichever hop runs first.
    private nonisolated let stopped = StateSync(false)
    private var observers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private var memorySource: DispatchSourceMemoryPressure?

    init() {
        // Bounded: the actor drains faster than the OS notifies; a stall keeps the latest changes.
        (stream, changes) = AsyncStream.makeStream(of: Change.self, bufferingPolicy: .bufferingNewest(64))
    }

    nonisolated func start() {
        Task { await self.observe() }
    }

    /// Called by the core on the caller's thread under its lifecycle lock: ends the stream at once
    /// (nothing more reaches the core) and unregisters on the actor later; never blocks.
    nonisolated func stop() {
        stopped.mutate { $0 = true }
        changes.finish()
        Task { await self.cancel() }
    }
}

// MARK: - Lifecycle

private extension DeviceTelemetry {
    func observe() {
        guard !stopped.copy() else { return }
        loop = Task { [weak self, stream] in
            for await change in stream {
                await self?.apply(change)
            }
        }.cancellable()
        observeProcessInfo()
        observeMemory()
        observeNetwork() // delivers the current path at once: the first state push
        observeBattery()
        observeAudioSession()
        observeAppState()
    }

    func cancel() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        pathMonitor?.cancel()
        memorySource?.cancel()
        loop = nil
        changes.finish()
        Task { @MainActor in AppStateListener.shared.delegates.remove(delegate: self) }
    }

    func apply(_ change: Change) {
        switch change {
        case .power: break
        case let .app(appState): state.appState = appState
        case let .memory(pressure): state.memory = pressure
        case let .network(type, expensive, constrained):
            (state.network, state.networkExpensive, state.networkConstrained) = (type, expensive, constrained)
        case let .battery(level, charging): (state.batteryLevel, state.batteryCharging) = (level, charging)
        case let .event(event):
            telemetryDeviceEvent(event: event)
            return
        }
        let info = ProcessInfo.processInfo
        state.thermal = ThermalState(info.thermalState)
        if #available(macOS 12.0, *) { state.lowPowerMode = info.isLowPowerModeEnabled }
        telemetrySetDeviceState(state: state)
    }

    func observe(_ name: Notification.Name, _ change: @escaping @Sendable (Notification) -> Change?) {
        let changes = changes
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
            if let change = change(note) { changes.yield(change) }
        })
    }
}

// MARK: - Power & thermal

private extension DeviceTelemetry {
    func observeProcessInfo() {
        observe(ProcessInfo.thermalStateDidChangeNotification) { _ in .power }
        if #available(macOS 12.0, *) {
            observe(.NSProcessInfoPowerStateDidChange) { _ in .power }
        }
    }
}

// MARK: - Memory

private extension DeviceTelemetry {
    /// `DISPATCH_MEMORYPRESSURE_*`: the signal jetsam acts on, including the return to normal.
    func observeMemory() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: Self.queue)
        let changes = changes
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            changes.yield(.memory(event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal))
        }
        source.resume()
        memorySource = source
    }
}

// MARK: - Network

private extension DeviceTelemetry {
    /// Path type, expensive (cellular, hotspot) and constrained (Low Data Mode).
    func observeNetwork() {
        let monitor = NWPathMonitor()
        let changes = changes
        monitor.pathUpdateHandler = { path in
            changes.yield(.network(NetworkType(path), expensive: path.isExpensive, constrained: path.isConstrained))
        }
        monitor.start(queue: Self.queue)
        pathMonitor = monitor
    }
}

// MARK: - Battery

private extension DeviceTelemetry {
    func observeBattery() {
        #if os(iOS) || os(visionOS)
        let changes = changes
        let read: @Sendable () -> Void = {
            Task { @MainActor in
                let device = UIDevice.current
                device.isBatteryMonitoringEnabled = true // ponytail: stays on for the process
                let level = device.batteryLevel // -1 while unknown
                changes.yield(.battery(level: level < 0 ? nil : UInt32((level * 100).rounded()),
                                       charging: device.batteryState == .charging || device.batteryState == .full))
            }
        }
        read()
        observe(UIDevice.batteryLevelDidChangeNotification) { _ in read(); return nil }
        observe(UIDevice.batteryStateDidChangeNotification) { _ in read(); return nil }
        #endif
    }
}

// MARK: - Audio session

private extension DeviceTelemetry {
    /// Route changes and interruptions are events, not state: they explain audio glitches.
    func observeAudioSession() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        observe(AVAudioSession.routeChangeNotification) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) ?? .unknown
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { AudioOutput($0.portType) }
            return .event(.audioRouteChanged(outputs: outputs, reason: AudioRouteReason(reason)))
        }
        observe(AVAudioSession.interruptionNotification) { note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            return .event(.audioInterruption(began: began))
        }
        #endif
    }
}

// MARK: - App state

private extension DeviceTelemetry {
    func observeAppState() {
        let changes = changes
        let stopped = stopped
        Task { @MainActor in
            // Checked here too: the remove, queued by a later stop(), must not run before this add.
            guard !stopped.copy() else { return }
            AppStateListener.shared.delegates.add(delegate: self)
            #if canImport(UIKit) && (os(iOS) || os(visionOS) || os(tvOS)) && !targetEnvironment(macCatalyst)
            if let state = applicationState() { changes.yield(.app(state == .background ? .background : .foreground)) }
            #endif
        }
    }
}

extension DeviceTelemetry: AppStateDelegate {
    nonisolated func appDidEnterBackground() { changes.yield(.app(.background)) }
    nonisolated func appWillEnterForeground() { changes.yield(.app(.foreground)) }
    nonisolated func appWillTerminate() { changes.yield(.app(.background)) }
    nonisolated func appWillSleep() { changes.yield(.app(.background)) }
    nonisolated func appDidWake() { changes.yield(.app(.foreground)) }
}

// MARK: - Vocabulary

extension ThermalState {
    init(_ state: ProcessInfo.ThermalState) {
        self = switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }
}

extension NetworkType {
    init(_ path: NWPath) {
        self = if path.status != .satisfied {
            .unavailable
        } else if path.usesInterfaceType(.wifi) {
            .wifi
        } else if path.usesInterfaceType(.cellular) {
            .cell
        } else if path.usesInterfaceType(.wiredEthernet) {
            .wired
        } else if path.usesInterfaceType(.other) {
            .other
        } else {
            .unknown
        }
    }
}

#if os(iOS) || os(tvOS) || os(visionOS)
extension AudioRouteReason {
    init(_ reason: AVAudioSession.RouteChangeReason) {
        self = switch reason {
        case .newDeviceAvailable: .newDevice
        case .oldDeviceUnavailable: .oldDeviceUnavailable
        case .categoryChange: .categoryChange
        case .override: .override
        case .wakeFromSleep: .wakeFromSleep
        case .noSuitableRouteForCategory: .noSuitableRoute
        case .routeConfigurationChange: .routeConfigurationChange
        default: .unknown
        }
    }
}

extension AudioOutput {
    init(_ port: AVAudioSession.Port) {
        self = switch port {
        case .builtInSpeaker: .speaker
        case .builtInReceiver: .receiver
        case .headphones, .lineOut: .wiredHeadset
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: .bluetooth
        case .carAudio: .carAudio
        case .airPlay: .airPlay
        case .HDMI: .hdmi
        case .usbAudio: .usb
        default: .other
        }
    }
}
#endif
