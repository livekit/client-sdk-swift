import Foundation

internal extension DispatchQueue {

    static let sdk = DispatchQueue(label: "LiveKitSDK", qos: .userInitiated)
    static let webRTC = DispatchQueue(label: "LiveKitSDK.webRTC", qos: .background)
    static let capture = DispatchQueue(label: "LiveKitSDK.capture", qos: .userInitiated)

    // execute work on the main thread if not already on the main thread
    static func mainSafeSync<T>(execute work: () throws -> T) rethrows -> T {
        guard !Thread.current.isMainThread else { return try work() }
        return try Self.main.sync(execute: work)
    }
}
