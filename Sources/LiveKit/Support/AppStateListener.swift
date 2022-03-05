import Foundation
#if os(iOS)
import UIKit
#endif

internal protocol AppStateDelegate: AnyObject {
    func appDidEnterBackground()
    func appWillEnterForeground()
    func appWillTerminate()
}

internal class AppStateListener: MulticastDelegate<AppStateDelegate> {

    static let shared = AppStateListener()

    private init() {
        super.init(qos: .userInitiated)

        let center = NotificationCenter.default

        #if os(iOS)
        center.addObserver(forName: UIScene.didEnterBackgroundNotification,
                           object: nil,
                           queue: OperationQueue.main) { (_) in

            self.log("UIScene.didEnterBackground")
            self.notify { $0.appDidEnterBackground() }
        }

        center.addObserver(forName: UIScene.willEnterForegroundNotification,
                           object: nil,
                           queue: OperationQueue.main) { (_) in

            self.log("UIScene.willEnterForeground")
            self.notify { $0.appWillEnterForeground() }
        }

        center.addObserver(forName: UIScene.didDisconnectNotification,
                           object: nil,
                           queue: OperationQueue.main) { (_) in

            self.log("UIScene.didDisconnect")
            self.notify { $0.appWillTerminate() }
        }
        #endif
    }
}
