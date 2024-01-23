import Foundation

@objc
public protocol AudioProcessor: AudioCustomProcessingDelegate {
    func isEnabled(url: String, token: String) -> Bool
    func getName() -> String
}
