import Foundation

/// Default timeout `TimeInterval`s used throughout the SDK.
internal extension TimeInterval {
    static let captureStart: Self = 5
    static let defaultConnect: Self = 15
    static let defaultConnectivity: Self = 10
    static let defaultPublish: Self = 10
    static let quickReconnectDelay: Self = 3
}
