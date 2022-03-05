import Foundation
#if os(iOS)
import UIKit
#endif

internal protocol AppStateDelegate: AnyObject {
    func appDidEnterBackground()
    func appWillEnterForeground()
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

            self.log("didEnterBackground")
            self.notify { $0.appDidEnterBackground() }
        }

        center.addObserver(forName: UIScene.willEnterForegroundNotification,
                           object: nil,
                           queue: OperationQueue.main) { (_) in

            self.log("willEnterForeground")
            self.notify { $0.appWillEnterForeground() }
        }
        #endif
    }
}
