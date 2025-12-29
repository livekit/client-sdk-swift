/*
 * Copyright 2025 LiveKit
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
import Network

protocol ConnectivityListenerDelegate: AnyObject, Sendable {
    func connectivityListener(_: ConnectivityListener, didUpdate hasConnectivity: Bool)
    // network remains to have connectivity but path changed
    func connectivityListener(_: ConnectivityListener, didSwitch path: NWPath)
}

extension ConnectivityListenerDelegate {
    func connectivityListener(_: ConnectivityListener, didUpdate _: Bool) {}
    func connectivityListener(_: ConnectivityListener, didSwitch _: NWPath) {}
}

class ConnectivityListener: MulticastDelegate<ConnectivityListenerDelegate>, @unchecked Sendable {
    static let shared = ConnectivityListener()

    private(set) var hasConnectivity: Bool? {
        didSet {
            guard let newValue = hasConnectivity, oldValue != newValue else { return }
            notify { $0.connectivityListener(self, didUpdate: newValue) }
        }
    }

    private(set) var ipv4: String?
    private(set) var path: NWPath?

    private let queue = DispatchQueue(label: "LiveKitSDK.connectivityListener", qos: .default)

    private let monitor = NWPathMonitor()

    // timer and flag used to handle the case when state transitions from:
    // satisfied -> unsatisfied -> satisfied
    // network doesn't always switch from?
    // satisfied -> satisfied
    private var isPossiblySwitchingNetwork: Bool = false
    private var switchNetworkTimer: Timer?
    private let switchInterval: TimeInterval = 3

    private init() {
        super.init(label: "ConnectivityListenerDelegate")

        log("initial path: \(monitor.currentPath), has: \(monitor.currentPath.isSatisfied())")

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            set(path: path)
        }

        monitor.start(queue: queue)
    }

    deinit {
        switchNetworkTimer?.invalidate()
        switchNetworkTimer = nil
    }
}

extension ConnectivityListener {
    func activeInterfaceType() -> NWInterface.InterfaceType? {
        let path = monitor.currentPath
        return path.availableInterfaces.filter {
            path.usesInterfaceType($0.type)
        }.first?.type
    }
}

private extension ConnectivityListener {
    func set(path newValue: NWPath, notify _: Bool = false) {
        log("status: \(newValue.status), interfaces: \(newValue.availableInterfaces.map { "\(String(describing: $0.type))-\(String(describing: $0.index))" }), gateways: \(newValue.gateways), activeIp: \(String(describing: newValue.availableInterfaces.first?.ipv4))")

        // check if different path
        guard newValue != path else { return }

        // keep old values
        let oldValue = path
        let oldIpValue = ipv4

        // update new values
        let newIpValue = newValue.availableInterfaces.first?.ipv4
        path = newValue
        ipv4 = newIpValue
        hasConnectivity = newValue.isSatisfied()

        // continue if old value exists
        guard let oldValue else { return }

        if oldValue.isSatisfied(), !newValue.isSatisfied() {
            // satisfied -> unsatisfied
            // active connection did disconnect
            log("starting satisfied monitor timer")
            isPossiblySwitchingNetwork = true
            switchNetworkTimer?.invalidate()
            switchNetworkTimer = Timer.scheduledTimer(withTimeInterval: switchInterval,
                                                      repeats: false)
            { [weak self] _ in
                guard let self else { return }
                log("satisfied monitor timer invalidated")
                isPossiblySwitchingNetwork = false
                switchNetworkTimer = nil
            }
        } else if !oldValue.isSatisfied(), newValue.isSatisfied(), isPossiblySwitchingNetwork {
            // unsatisfied -> satisfied
            // did switch network
            switchNetworkTimer?.invalidate()
            switchNetworkTimer = nil
            isPossiblySwitchingNetwork = false

            log("didSwitch type: quick on & off")
            notify { $0.connectivityListener(self, didSwitch: newValue) }
        } else if oldValue.isSatisfied(), newValue.isSatisfied() {
            // satisfied -> satisfied

            let oldInterface = oldValue.availableInterfaces.first
            let newInterface = newValue.availableInterfaces.first

            if (oldInterface != newInterface) // active interface changed
                || (oldIpValue != newIpValue) // or, same interface but ip changed (detect wifi network switch)
            {
                log("didSwitch type: network or ip change")
                notify { $0.connectivityListener(self, didSwitch: newValue) }
            }
        }
    }
}

extension NWPath {
    func isSatisfied() -> Bool {
        if case .satisfied = status { return true }
        return false
    }
}

extension NWInterface {
    func address(family: Int32) -> String? {
        var address: String?

        // get list of all interfaces on the local machine:
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }

        // for each interface ...
        for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee

            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(family) {
                // Check interface name:
                if name == String(cString: interface.ifa_name) {
                    // Convert interface address to a human readable string:
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname, encoding: .utf8)
                }
            }
        }
        freeifaddrs(ifaddr)

        return address
    }

    var ipv4: String? { address(family: AF_INET) }
    var ipv6: String? { address(family: AF_INET6) }
}
