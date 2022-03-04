import Foundation
#if os(iOS)
import UIKit
#endif

internal class AppStateListener: Loggable {

    typealias EventHandler = () -> Void

    var onEnterBackground: EventHandler?
    var onEnterForeground: EventHandler?

    init() {
        let center = NotificationCenter.default

        #if os(iOS)
        center.addObserver(forName: UIScene.didEnterBackgroundNotification,
                           object: nil,
                           queue: OperationQueue.main) { (_) in

            self.log("UIScene.didEnterBackgroundNotification")
            self.onEnterBackground?()
        }

        center.addObserver(forName: UIScene.didDisconnectNotification,
                           object: nil,
                           queue: OperationQueue.main) { (_) in

            self.log("UIScene.didDisconnectNotification")
            self.onEnterForeground?()
        }
        #endif
    }
}
