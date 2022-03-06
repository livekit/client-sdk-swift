import Network

internal enum NetworkState {
    case connected
    case disconnected
}

internal protocol ConnectivityListenerDelegate: AnyObject {
    func networkStateDidUpdate(_ state: NetworkState)
    // the active interface has changed
    func networkMonitor(_ networkMonitor: ConnectivityListener, didUpdate activeInterface: NWInterface)
}

internal extension NWPath {
    
    func toNetworkState() -> NetworkState {
        if case .satisfied = status { return .connected }
        return .disconnected
    }
}

internal class ConnectivityListener: MulticastDelegate<ConnectivityListenerDelegate> {
    
    static let shared = ConnectivityListener()

    public private(set) var state: NetworkState {
        didSet {
            guard oldValue != state else { return }
            notify { $0.networkStateDidUpdate(self.state) }
        }
    }
    
    public private(set) var activeInterface: NWInterface? {
        didSet {
            guard let activeInterface = activeInterface else { return }
            
            guard let oldValue = oldValue else {
                // if previous value was nil, always notify
                return notify { $0.networkMonitor(self, didUpdate: activeInterface) }
            }
            
            guard activeInterface.type != oldValue.type else { return }
            notify { $0.networkMonitor(self, didUpdate: activeInterface) }
        }
    }

    private let queue = DispatchQueue(label: "LiveKitSDK.networkMonitor")
    private let monitor = NWPathMonitor()
    
    private init() {
        // set initial values
        self.state = monitor.currentPath.toNetworkState()
        self.activeInterface = monitor.currentPath.availableInterfaces.first

        super.init()

        monitor.pathUpdateHandler = { path in
            //path.status == .satisfied

            self.log("networkPathDidUpdate status: \(path.status), interfaces: \(path.availableInterfaces.map({ "\(String(describing: $0.type))-\(String(describing: $0.index))" })), local: \(String(describing: path.localEndpoint)), remote: \(String(describing: path.remoteEndpoint)), gw: \(path.gateways)")

            self.state = path.toNetworkState()
            self.activeInterface = path.availableInterfaces.first
        }

        monitor.start(queue: queue)
    }
}
