import Foundation

internal extension CFMessagePort {

    private static var selfObjectHandle: UInt8 = 1

    func associatedSelf() -> IPCChannel? {
        objc_getAssociatedObject(self as Any, &CFMessagePort.selfObjectHandle) as? IPCChannel
    }

    func associateSelf(_ obj: IPCChannel) {
        // attach self
        objc_setAssociatedObject(self as Any,
                                 &CFMessagePort.selfObjectHandle,
                                 obj,
                                 objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

public typealias IPCOnDidUpdateConnectionState = (_ server: IPCChannel,
                                                  _ connected: Bool) -> Void

public typealias IPCOnReceivedData = (_ server: IPCChannel,
                                      _ messageId: Int32,
                                      _ data: Data) -> Void

/// Simple class for inter-process-communication which can be used for
/// communication between app and extension. This is a base class,
/// for more information see ``IPCServer``, ``IPCClient``.
///
/// `name` used between ``IPCServer`` and ``IPCClient`` must match to
/// establish a connection. `name` must start with an App Group ID. ex. `group.yourapp.ipc-name`.
public class IPCChannel {
    // mach ports are uni-directional so we need both server and client
    internal var serverPort: CFMessagePort?
    internal var clientPort: CFMessagePort?

    // true when bi-directional ipc connection is established
    public internal(set) var connected: Bool = false {
        didSet {
            guard oldValue != connected else { return }
            onDidUpdateConnectionState?(self, connected)
        }
    }

    public internal(set) var serverConnected: Bool = false {
        didSet {
            self.connected = serverConnected && clientConnected
        }
    }

    public internal(set) var clientConnected: Bool = false {
        didSet {
            self.connected = serverConnected && clientConnected
        }
    }

    // used for server
    private static let runLoopMode = CFRunLoopMode.commonModes
    public internal(set) var runLoop: CFRunLoop
    public internal(set) var runLoopSource: CFRunLoopSource?

    /// The callback will be called any time data is received.
    public var onReceivedData: IPCOnReceivedData?
    public var onDidUpdateConnectionState: IPCOnDidUpdateConnectionState?

    public init(onReceivedData: IPCOnReceivedData? = nil,
                runLoop: CFRunLoop = CFRunLoopGetMain()) {
        self.onReceivedData = onReceivedData
        self.runLoop = runLoop
    }

    public func close() {

        if let port = serverPort {
            if CFMessagePortIsValid(port) {
                CFMessagePortInvalidate(port)
            }
            serverPort = nil
        }

        if let port = clientPort {
            if CFMessagePortIsValid(port) {
                CFMessagePortInvalidate(port)
            }
            clientPort = nil
        }
    }

    internal func cleanUp() {
        logger.debug("\(self) cleanUp")
        serverConnected = false
        clientConnected = false
        self.serverPort = nil
        self.clientPort = nil

        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(runLoop, runLoopSource, IPCChannel.runLoopMode)
            self.runLoopSource = nil
        }
    }

    @discardableResult
    public func open(_ name: String) -> Bool {
        let namePrimary = "\(name).primary"
        let nameSecondary = "\(name).secondary"

        //        if connect(namePrimary) {
        //
        //        }

        if listen(namePrimary) && connect(nameSecondary) {
            return true
        } else {
            close()
            if listen(nameSecondary) && connect(namePrimary) {
                return true
            }
        }

        close()
        return false
    }

    /// Start listening for data sent from client.
    /// - Parameter name: A unique name for this server, must start with AppGroup ID.
    /// - Returns: `true` when successfully started listening.
    @discardableResult
    private func listen(_ name: String) -> Bool {

        guard serverPort == nil else {
            // port already exists
            logger.debug("serverPort is not nil \(name)")
            return false
        }

        serverPort = CFMessagePortCreateLocal(nil,
                                              name as CFString, { (port: CFMessagePort?,
                                                                   id: Int32,
                                                                   data: CFData?,
                                                                   _: UnsafeMutableRawPointer?) -> Unmanaged<CFData>? in
                                                // restore `self` from pointer
                                                guard let selfObj = port?.associatedSelf(),
                                                      let data = data as Data? else { return nil }
                                                selfObj.onReceivedData?(selfObj, id, data)
                                                return nil
                                              },
                                              nil,
                                              nil)

        guard let port = serverPort else { return false }

        // associate `self` to access from callbacks
        port.associateSelf(self)

        CFMessagePortSetInvalidationCallBack(port) { port, _ in
            // restore `self` from pointer
            guard let selfObj = port?.associatedSelf() else { return }
            selfObj.cleanUp()
        }

        if let source = CFMessagePortCreateRunLoopSource(nil, port, 0) {
            CFRunLoopAddSource(runLoop, source, IPCChannel.runLoopMode)
            self.runLoopSource = source
        } else {
            close()
            return false
        }

        serverConnected = true
        return true
    }

    // MARK: - Client methods

    @discardableResult
    private func connect(_ name: String) -> Bool {

        clientPort = CFMessagePortCreateRemote(nil, name as CFString)
        guard let port = clientPort else { return false }

        // attach `self` to port
        port.associateSelf(self)

        CFMessagePortSetInvalidationCallBack(port) { port, _ in
            // restore `self` from port
            guard let selfObj = port?.associatedSelf() else { return }
            selfObj.cleanUp()
        }

        clientConnected = true
        return true
    }

    @discardableResult
    public func send(_ data: Data, messageId: Int32 = 0) -> Bool {

        guard let port = clientPort else { return false }

        let result = CFMessagePortSendRequest(port,
                                              messageId,
                                              data as CFData,
                                              0.0,
                                              0.0,
                                              nil,
                                              nil)

        return result == Int32(kCFMessagePortSuccess)
    }
}
