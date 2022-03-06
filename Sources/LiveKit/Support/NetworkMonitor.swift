import Network

internal enum NetworkState {
    case connected
    case disconnected
}

internal protocol NetworkStateDelegate: AnyObject {
    func networkStateDidUpdate(_ state: NetworkState)
}

internal extension NWPath {
    
    func toNetworkState() -> NetworkState {
        if case .satisfied = status { return .connected }
        return .disconnected
    }
}

internal class NetworkStateListener: MulticastDelegate<NetworkStateDelegate> {
    
    static let shared = NetworkStateListener()

    public private(set) var state: NetworkState {
        didSet {
            guard oldValue != state else { return }
            notify { $0.networkStateDidUpdate(self.state) }
        }
    }
    
    private let queue = DispatchQueue(label: "LiveKitSDK.networkMonitor")
    private let monitor = NWPathMonitor()
    
    private init() {
        self.state = monitor.currentPath.toNetworkState()
        super.init()

        monitor.pathUpdateHandler = { path in
            //path.status == .satisfied
            // self.log("networkPathDidUpdate: \(path)")
            self.state = path.toNetworkState()
        }
        monitor.start(queue: queue)
    }
}
