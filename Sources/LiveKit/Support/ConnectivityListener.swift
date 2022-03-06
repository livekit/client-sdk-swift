import Network

internal protocol ConnectivityListenerDelegate: AnyObject {

    func connectivityListener(_: ConnectivityListener, didUpdate hasConnectivity: Bool)
    // network remains to have connectivity but path changed
    func connectivityListener(_: ConnectivityListener, didSwitch path: NWPath)
}

internal extension NWPath {

    func hasConnectivity() -> Bool {
        if case .satisfied = status { return true }
        return false
    }
}

internal class ConnectivityListener: MulticastDelegate<ConnectivityListenerDelegate> {

    static let shared = ConnectivityListener()

    public private(set) var hasConnectivity: Bool {
        didSet {
            guard oldValue != hasConnectivity else { return }
            notify { $0.connectivityListener(self, didUpdate: self.hasConnectivity) }
        }
    }

    public private(set) var path: NWPath {
        didSet {
            defer { self.hasConnectivity = path.hasConnectivity() }

            if oldValue.hasConnectivity(), path.hasConnectivity(),
               // first interface changed
               (oldValue.availableInterfaces.first != path.availableInterfaces.first)
                // same interface but gateways changed (detect wifi network switch)
                || (oldValue.gateways != path.gateways) {
                notify { $0.connectivityListener(self, didSwitch: self.path) }
            }
        }
    }

    private let queue = DispatchQueue(label: "LiveKitSDK.connectivityListener")
    private let monitor = NWPathMonitor()

    private init() {
        // set initial values
        self.path = monitor.currentPath
        self.hasConnectivity = monitor.currentPath.hasConnectivity()

        super.init()

        monitor.pathUpdateHandler = { path in

            self.log("NWPathDidUpdate status: \(path.status), interfaces: \(path.availableInterfaces.map({ "\(String(describing: $0.type))-\(String(describing: $0.index))" })), local: \(String(describing: path.localEndpoint)), remote: \(String(describing: path.remoteEndpoint)), gateways: \(path.gateways)")

            DispatchQueue.sdk.async {
                self.path = path
            }
        }

        monitor.start(queue: queue)
    }
}
