import Foundation

/// Default timeout `TimeInterval`s used throughout the SDK.
internal extension TimeInterval {
    static let defaultConnect: Self = 10
    static let defaultPublish: Self = 10
    static let reconnectDelay: Self = 2
}
