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

/// The Device-area instrument: thermal state, low-power mode, memory pressure, network path,
/// battery, app lifecycle and the audio session, observed process-wide (a device has no room) and
/// pushed to the pipeline as `DeviceState` — which stretches the cadence and holds uploads — plus
/// the `lk.device.*` events. Notification-driven throughout: nothing polls, nothing samples CPU.
@Telemetry
final class DeviceTelemetry: TelemetryInstrument, Loggable {
    private nonisolated let core: LiveKitUniFFI.Telemetry
    /// Instruments run here, never on a media or UI thread.
    private nonisolated let queue = DispatchQueue(label: "LiveKitSDK.telemetry.device", qos: .utility)
    private nonisolated let pathMonitor = NWPathMonitor()
    private var notificationTokens: [NSObjectProtocol] = []
    private var memorySource: DispatchSourceMemoryPressure?

    private var appState: LiveKitUniFFI.AppState = .foreground
    private var memory: MemoryPressure = .normal
    private var network: NetworkType = .unknown
    private var networkExpensive = false
    private var networkConstrained = false
    /// Percent; `nil` where unknown (macOS, tvOS).
    private var batteryLevel: UInt32?
    private var batteryCharging = false

    nonisolated init(core: LiveKitUniFFI.Telemetry) {
        self.core = core
    }

    func start() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @Telemetry in self?.pushDeviceState() }
        })
        if #available(macOS 12.0, iOS 9.0, tvOS 9.0, *) {
            notificationTokens.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
                Task { @Telemetry in self?.pushDeviceState() }
            })
        }
        Task { @MainActor in AppStateListener.shared.delegates.add(delegate: self) }
        observeMemory()
        observeNetwork()
        observeBattery()
        observeAudioSession()
        pushDeviceState()
    }

    func stop() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        memorySource?.cancel()
        memorySource = nil
        pathMonitor.cancel()
        Task { @MainActor in AppStateListener.shared.delegates.remove(delegate: self) }
    }

    // MARK: - Device state

    private func pushDeviceState() {
        let info = ProcessInfo.processInfo
        var lowPower = false
        #if os(iOS) || os(tvOS) || os(visionOS)
        lowPower = info.isLowPowerModeEnabled
        #else
        if #available(macOS 12.0, *) { lowPower = info.isLowPowerModeEnabled }
        #endif
        core.setDeviceState(state: DeviceState(thermal: Self.thermal(info.thermalState),
                                               lowPowerMode: lowPower,
                                               appState: appState,
                                               memory: memory,
                                               network: network,
                                               networkExpensive: networkExpensive,
                                               networkConstrained: networkConstrained,
                                               batteryLevel: batteryLevel,
                                               batteryCharging: batteryCharging))
    }

    private func setAppState(_ appState: LiveKitUniFFI.AppState) {
        self.appState = appState
        pushDeviceState()
    }

    /// `DISPATCH_MEMORYPRESSURE_*`: the same source jetsam uses, on every Apple platform, and it
    /// also reports the return to normal (a memory *warning* notification does not).
    private func observeMemory() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            let pressure: MemoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            Task { @Telemetry in
                guard let self else { return }
                self.memory = pressure
                self.pushDeviceState()
            }
        }
        source.resume()
        memorySource = source
    }

    /// Path type plus the two flags that matter for traffic: expensive (cellular/hotspot) and
    /// constrained (Low Data Mode — the user asked for less).
    private func observeNetwork() {
        // Seed from the current path so the first state is not a spurious `unknown`.
        record(pathMonitor.currentPath)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @Telemetry in
                guard let self else { return }
                self.record(path)
                self.pushDeviceState()
            }
        }
        pathMonitor.start(queue: queue)
    }

    private func record(_ path: NWPath) {
        network = Self.networkType(path)
        networkExpensive = path.isExpensive
        networkConstrained = path.isConstrained
    }

    private func observeBattery() {
        #if os(iOS) || os(visionOS)
        // ponytail: monitoring stays enabled for the process; apps toggling it themselves are unaffected.
        Task { @MainActor in
            UIDevice.current.isBatteryMonitoringEnabled = true
            self.readBattery()
        }
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            notificationTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.readBattery() }
            })
        }
        #endif
    }

    #if os(iOS) || os(visionOS)
    @MainActor private nonisolated func readBattery() {
        let device = UIDevice.current
        let level = device.batteryLevel // -1 while unknown
        let percent: UInt32? = level < 0 ? nil : UInt32((level * 100).rounded())
        let charging = device.batteryState == .charging || device.batteryState == .full
        Task { @Telemetry in
            self.batteryLevel = percent
            self.batteryCharging = charging
            self.pushDeviceState()
        }
    }
    #endif

    /// Route changes and interruptions are events, not state: they explain audio glitches.
    private func observeAudioSession() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) ?? .unknown
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
            self?.emit("lk.device.audio_route.changed", [
                .init(key: "lk.device.audio_route.reason", value: .str(Self.name(reason))),
                .init(key: "lk.device.audio_route.outputs", value: .str(outputs)),
            ])
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
            self?.emit("lk.device.audio.interruption", [
                .init(key: "lk.device.audio.interruption", value: .str(began ? "began" : "ended")),
            ])
        })
        #endif
    }

    private nonisolated func emit(_ name: String, _ attributes: [LiveKitUniFFI.Attribute]) {
        core.emit(event: TelemetryEvent(name: name, severity: .info, body: nil, attributes: attributes, spanId: nil))
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    private nonisolated static func name(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: "new_device_available"
        case .oldDeviceUnavailable: "old_device_unavailable"
        case .categoryChange: "category_change"
        case .override: "override"
        case .wakeFromSleep: "wake_from_sleep"
        case .noSuitableRouteForCategory: "no_suitable_route"
        case .routeConfigurationChange: "route_configuration_change"
        default: "unknown"
        }
    }
    #endif

    private nonisolated static func thermal(_ state: ProcessInfo.ThermalState) -> ThermalState {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    private nonisolated static func networkType(_ path: NWPath) -> NetworkType {
        guard path.status == .satisfied else { return .unavailable }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cell }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .unknown
    }
}

// MARK: - App state

extension DeviceTelemetry: AppStateDelegate {
    nonisolated func appDidEnterBackground() { Task { @Telemetry in self.setAppState(.background) } }
    nonisolated func appWillEnterForeground() { Task { @Telemetry in self.setAppState(.foreground) } }
    nonisolated func appWillSleep() { Task { @Telemetry in self.setAppState(.background) } }
    nonisolated func appDidWake() { Task { @Telemetry in self.setAppState(.foreground) } }

    /// The last chance to ship: the shutdown summary included.
    nonisolated func appWillTerminate() {
        Task { @Telemetry in
            self.setAppState(.background)
            await Telemetry.shutdown()
        }
    }
}
