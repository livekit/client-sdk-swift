import Foundation

internal extension CFMessagePort {

    private static var selfObjectHandle: UInt8 = 1

    func associatedSelf() -> IPC? {
        objc_getAssociatedObject(self as Any, &CFMessagePort.selfObjectHandle) as? IPC
    }

    func associateSelf(_ obj: IPC) {
        // attach self
        objc_setAssociatedObject(self as Any,
                                 &CFMessagePort.selfObjectHandle,
                                 obj,
                                 objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

public typealias IPCOnReceivedData = (_ server: IPCServer,
                                      _ messageId: Int32,
                                      _ data: Data) -> Void

/// Simple class for inter-process-communication which can be used for
/// communication between app and extension. This is a base class,
/// for more information see ``IPCServer``, ``IPCClient``.
///
/// `name` used between ``IPCServer`` and ``IPCClient`` must match to
/// establish a connection. `name` must start with an App Group ID. ex. `group.yourapp.ipc-name`.
public class IPC: Loggable {
    internal var port: CFMessagePort?
    public internal(set) var connected: Bool = false

    internal init () {}

    public func close() {
        guard let port = port else { return }
        CFMessagePortInvalidate(port)
    }

    internal func cleanUp() {
        log("\(self) cleanUp")
        connected = false
        self.port = nil
    }
}

public class IPCServer: IPC {

    private static let runLoopMode = CFRunLoopMode.commonModes
    public internal(set) var runLoop: CFRunLoop
    public internal(set) var runLoopSource: CFRunLoopSource?

    /// The callback will be called any time data is received.
    public var onReceivedData: IPCOnReceivedData?

    public init(onReceivedData: IPCOnReceivedData? = nil,
                runLoop: CFRunLoop = CFRunLoopGetMain()) {
        self.onReceivedData = onReceivedData
        self.runLoop = runLoop
        super.init()
    }

    override func cleanUp() {
        super.cleanUp()
        guard let runLoopSource = runLoopSource else { return }
        CFRunLoopRemoveSource(runLoop, runLoopSource, IPCServer.runLoopMode)
        self.runLoopSource = nil
    }

    /// Start listening for data sent from client.
    /// - Parameter name: A unique name for this server, must start with AppGroup ID.
    /// - Returns: `true` when successfully started listening.
    @discardableResult
    public func listen(_ name: String) -> Bool {

        guard port == nil else {
            // port already exists
            log("port is not nil")
            return false
        }

        port = CFMessagePortCreateLocal(nil,
                                        name as CFString, { (port: CFMessagePort?,
                                                             id: Int32,
                                                             data: CFData?,
                                                             _: UnsafeMutableRawPointer?) -> Unmanaged<CFData>? in
                                            // restore `self` from pointer
                                            guard let selfObj = port?.associatedSelf() as? IPCServer,
                                                  let data = data as Data? else { return nil }
                                            selfObj.onReceivedData?(selfObj, id, data)
                                            return nil
                                        },
                                        nil,
                                        nil)
        if let port = port {
            // associate `self` to access from callbacks
            port.associateSelf(self)

            CFMessagePortSetInvalidationCallBack(port) { port, _ in
                // restore `self` from pointer
                guard let selfObj = port?.associatedSelf() else { return }
                selfObj.cleanUp()
            }

            if let source = CFMessagePortCreateRunLoopSource(nil, port, 0) {
                CFRunLoopAddSource(runLoop, source, IPCServer.runLoopMode)
                self.runLoopSource = source
            } else {
                close()
                return false
            }

            connected = true
            return true
        }

        return false
    }
}

public class IPCClient: IPC {

    private static var selfObjectHandle: UInt8 = 1

    public override init() {}

    @discardableResult
    public func connect(_ name: String) -> Bool {
        port = CFMessagePortCreateRemote(nil, name as CFString)
        if let port = port {
            // attach `self` to port
            port.associateSelf(self)

            CFMessagePortSetInvalidationCallBack(port) { port, _ in
                // restore `self` from port
                guard let selfObj = port?.associatedSelf() else { return }
                selfObj.cleanUp()
            }

            connected = true
            return true
        }
        return false
    }

    @discardableResult
    public func send(_ data: Data, messageId: Int32 = 0) -> Bool {

        guard let port = port else { return false }

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
