import WebRTC

extension RTCPeerConnectionState: CustomStringConvertible {

    public var description: String {
        switch self {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        @unknown default: return "unknown"
        }
    }
}
